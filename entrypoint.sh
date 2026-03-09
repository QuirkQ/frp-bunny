#!/bin/sh
set -eu

FRP_MODE="${FRP_MODE:-server}"

case "$FRP_MODE" in
  server|client) ;;
  *) echo "ERROR: FRP_MODE must be 'server' or 'client', got: $FRP_MODE" >&2; exit 1 ;;
esac

# --- User setup ---

PUID="${PUID:-1000}"
PGID="${PGID:-1000}"

setup_user() {
  CUR_UID=$(id -u frp)
  CUR_GID=$(id -g frp)

  if [ "$CUR_GID" != "$PGID" ]; then
    sed -i "s/^frp:x:${CUR_GID}:/frp:x:${PGID}:/" /etc/group
    sed -i "s/^\(frp:[^:]*:[^:]*:\)${CUR_GID}:/\1${PGID}:/" /etc/passwd
  fi

  if [ "$CUR_UID" != "$PUID" ]; then
    sed -i "s/^frp:\([^:]*\):${CUR_UID}:/frp:\1:${PUID}:/" /etc/passwd
  fi

  chown frp:frp /etc/frp
}

# Adjust UID/GID if running as root
if [ "$(id -u)" = "0" ]; then
  setup_user
fi

# --- Decode base64 certificates from env vars ---

TLS_DIR="/etc/frp/tls"

decode_cert() {
  var_name="$1"
  dest="$2"
  mode="$3"

  eval val=\${${var_name}:-}
  if [ -n "$val" ]; then
    mkdir -p "$TLS_DIR"
    echo "$val" | base64 -d > "$dest"
    chmod "$mode" "$dest"
    chown frp:frp "$dest" 2>/dev/null || true
  fi
}

if [ "$FRP_MODE" = "server" ]; then
  decode_cert TLS_CERT_B64  "$TLS_DIR/server.crt" 644
  decode_cert TLS_KEY_B64   "$TLS_DIR/server.key" 600
else
  decode_cert TLS_CERT_B64  "$TLS_DIR/client.crt" 644
  decode_cert TLS_KEY_B64   "$TLS_DIR/client.key" 600
fi
decode_cert TLS_CA_B64    "$TLS_DIR/ca.crt"     644

# --- Common validation ---

if [ -z "${FRP_TOKEN:-}" ]; then
  echo "ERROR: FRP_TOKEN environment variable is required" >&2
  exit 1
fi

is_port() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

is_uint() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$1" -ge 0 ]
}

HEALTH_PORT="${HEALTH_PORT:-8080}"

# Escape strings for safe TOML embedding (backslashes then double quotes)
esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# ============================
# SERVER MODE
# ============================

generate_server_config() {
  BIND_PORT="${BIND_PORT:-7000}"
  VHOST_HTTPS_PORT="${VHOST_HTTPS_PORT:-443}"
  VHOST_HTTP_PORT="${VHOST_HTTP_PORT:-80}"
  DASHBOARD_PORT="${DASHBOARD_PORT:-7500}"
  DASHBOARD_ADDR="${DASHBOARD_ADDR:-127.0.0.1}"
  MAX_PORTS_PER_CLIENT="${MAX_PORTS_PER_CLIENT:-0}"
  MAX_POOL_COUNT="${MAX_POOL_COUNT:-10}"
  ALLOW_PORTS="${ALLOW_PORTS:-}"

  PORT_VARS="BIND_PORT VHOST_HTTPS_PORT VHOST_HTTP_PORT DASHBOARD_PORT"

  for var in $PORT_VARS; do
    eval val=\$$var
    if ! is_port "$val"; then
      echo "ERROR: $var must be a valid port number (1-65535), got: $val" >&2
      exit 1
    fi
  done

  if [ -n "$HEALTH_PORT" ] && [ "$HEALTH_PORT" != "0" ] && ! is_port "$HEALTH_PORT"; then
    echo "ERROR: HEALTH_PORT must be a valid port number (1-65535) or 0, got: $HEALTH_PORT" >&2
    exit 1
  fi

  for var in MAX_PORTS_PER_CLIENT MAX_POOL_COUNT; do
    eval val=\$$var
    if ! is_uint "$val"; then
      echo "ERROR: $var must be a non-negative integer, got: $val" >&2
      exit 1
    fi
  done

  # Convert ALLOW_PORTS (e.g. "10000-50000,60000-60100") to TOML array of ranges
  build_allow_ports() {
    printf 'allowPorts = [\n'
    echo "$1" | tr ',' '\n' | while IFS='-' read -r start end; do
      start=$(echo "$start" | tr -d ' ')
      end=$(echo "${end:-$start}" | tr -d ' ')
      printf '  { start = %s, end = %s },\n' "$start" "$end"
    done
    printf ']\n'
  }

  cat > /etc/frp/frps.toml <<EOF
bindAddr = "0.0.0.0"
bindPort = ${BIND_PORT}

auth.token = "$(esc "$FRP_TOKEN")"
auth.additionalScopes = ["HeartBeats", "NewWorkConns"]

# Require TLS between frpc and frps
transport.tls.force = true
transport.maxPoolCount = ${MAX_POOL_COUNT}

# Limit attack surface from a compromised token
maxPortsPerClient = ${MAX_PORTS_PER_CLIENT}
detailedErrorsToClient = false
EOF

  # Restrict which ports clients may bind (empty = no TCP port binding allowed)
  if [ -n "$ALLOW_PORTS" ]; then
    build_allow_ports "$ALLOW_PORTS" >> /etc/frp/frps.toml
  fi

  # TLS certificates: use if mounted (enables server identity verification by frpc)
  if [ -f "${TLS_CERT_FILE:-/etc/frp/tls/server.crt}" ] && [ -f "${TLS_KEY_FILE:-/etc/frp/tls/server.key}" ]; then
    TLS_CERT_FILE="${TLS_CERT_FILE:-/etc/frp/tls/server.crt}"
    TLS_KEY_FILE="${TLS_KEY_FILE:-/etc/frp/tls/server.key}"
    cat >> /etc/frp/frps.toml <<EOF

transport.tls.certFile = "$(esc "$TLS_CERT_FILE")"
transport.tls.keyFile = "$(esc "$TLS_KEY_FILE")"
EOF
  fi

  # mTLS: if a CA cert is mounted, require client certificates
  if [ -f "${TLS_CA_FILE:-/etc/frp/tls/ca.crt}" ]; then
    TLS_CA_FILE="${TLS_CA_FILE:-/etc/frp/tls/ca.crt}"
    cat >> /etc/frp/frps.toml <<EOF
transport.tls.trustedCaFile = "$(esc "$TLS_CA_FILE")"
EOF
  fi

  # Dashboard: only enabled when DASHBOARD_PASSWORD is set
  if [ -n "${DASHBOARD_PASSWORD:-}" ]; then
    cat >> /etc/frp/frps.toml <<EOF

webServer.addr = "$(esc "$DASHBOARD_ADDR")"
webServer.port = ${DASHBOARD_PORT}
webServer.user = "$(esc "${DASHBOARD_USER:-admin}")"
webServer.password = "$(esc "$DASHBOARD_PASSWORD")"
EOF

    # Dashboard TLS: reuse server certs if available
    if [ -f "${TLS_CERT_FILE:-/etc/frp/tls/server.crt}" ] && [ -f "${TLS_KEY_FILE:-/etc/frp/tls/server.key}" ]; then
      cat >> /etc/frp/frps.toml <<EOF
webServer.tls.certFile = "$(esc "${TLS_CERT_FILE:-/etc/frp/tls/server.crt}")"
webServer.tls.keyFile = "$(esc "${TLS_KEY_FILE:-/etc/frp/tls/server.key}")"
EOF
    fi

    # Prometheus: opt-in via env var
    if [ "${ENABLE_PROMETHEUS:-false}" = "true" ]; then
      echo 'enablePrometheus = true' >> /etc/frp/frps.toml
    fi
  fi

  # Vhost: HTTPS (SNI routing) + HTTP (for redirects and ACME challenges)
  echo "vhostHTTPSPort = ${VHOST_HTTPS_PORT}" >> /etc/frp/frps.toml
  echo "vhostHTTPPort = ${VHOST_HTTP_PORT}" >> /etc/frp/frps.toml

  # Subdomain restriction: only when explicitly set
  if [ -n "${SUBDOMAIN_HOST:-}" ]; then
    echo "subDomainHost = \"$(esc "$SUBDOMAIN_HOST")\"" >> /etc/frp/frps.toml
  fi

  chmod 400 /etc/frp/frps.toml
  chown frp:frp /etc/frp/frps.toml 2>/dev/null || true
}

# ============================
# CLIENT MODE
# ============================

generate_client_config() {
  SERVER_ADDR="${SERVER_ADDR:-}"
  SERVER_PORT="${SERVER_PORT:-7000}"
  LOGIN_FAIL_EXIT="${LOGIN_FAIL_EXIT:-false}"

  if [ -z "$SERVER_ADDR" ]; then
    echo "ERROR: SERVER_ADDR environment variable is required in client mode" >&2
    exit 1
  fi

  if ! is_port "$SERVER_PORT"; then
    echo "ERROR: SERVER_PORT must be a valid port number (1-65535), got: $SERVER_PORT" >&2
    exit 1
  fi

  if [ -n "$HEALTH_PORT" ] && [ "$HEALTH_PORT" != "0" ] && ! is_port "$HEALTH_PORT"; then
    echo "ERROR: HEALTH_PORT must be a valid port number (1-65535), got: $HEALTH_PORT" >&2
    exit 1
  fi

  # Prepare conf.d directory for proxy includes
  CONF_DIR="/etc/frp/conf.d"
  mkdir -p "$CONF_DIR"
  chown frp:frp "$CONF_DIR" 2>/dev/null || true

  # Decode base64-encoded proxy definitions if provided
  if [ -n "${FRP_PROXIES_B64:-}" ]; then
    echo "$FRP_PROXIES_B64" | base64 -d > "$CONF_DIR/proxies.toml"
    chmod 400 "$CONF_DIR/proxies.toml"
    chown frp:frp "$CONF_DIR/proxies.toml" 2>/dev/null || true
  fi

  POOL_COUNT="${POOL_COUNT:-5}"
  HEARTBEAT_INTERVAL="${HEARTBEAT_INTERVAL:-3}"
  HEARTBEAT_TIMEOUT="${HEARTBEAT_TIMEOUT:-9}"

  if ! is_uint "$POOL_COUNT"; then
    echo "ERROR: POOL_COUNT must be a non-negative integer, got: $POOL_COUNT" >&2
    exit 1
  fi

  cat > /etc/frp/frpc.toml <<EOF
serverAddr = "$(esc "$SERVER_ADDR")"
serverPort = ${SERVER_PORT}

auth.token = "$(esc "$FRP_TOKEN")"
auth.additionalScopes = ["HeartBeats", "NewWorkConns"]

loginFailExit = ${LOGIN_FAIL_EXIT}

transport.tls.enable = true
transport.poolCount = ${POOL_COUNT}
transport.tcpMux = true
transport.tcpMuxKeepaliveInterval = ${HEARTBEAT_INTERVAL}
transport.heartbeatInterval = ${HEARTBEAT_INTERVAL}
transport.heartbeatTimeout = ${HEARTBEAT_TIMEOUT}
transport.dialServerTimeout = 5
transport.dialServerKeepalive = 10
EOF

  # TLS client certificate (for mTLS)
  if [ -f "${TLS_CERT_FILE:-/etc/frp/tls/client.crt}" ] && [ -f "${TLS_KEY_FILE:-/etc/frp/tls/client.key}" ]; then
    TLS_CERT_FILE="${TLS_CERT_FILE:-/etc/frp/tls/client.crt}"
    TLS_KEY_FILE="${TLS_KEY_FILE:-/etc/frp/tls/client.key}"
    cat >> /etc/frp/frpc.toml <<EOF

transport.tls.certFile = "$(esc "$TLS_CERT_FILE")"
transport.tls.keyFile = "$(esc "$TLS_KEY_FILE")"
EOF
  fi

  # CA certificate for verifying the server
  if [ -f "${TLS_CA_FILE:-/etc/frp/tls/ca.crt}" ]; then
    TLS_CA_FILE="${TLS_CA_FILE:-/etc/frp/tls/ca.crt}"
    cat >> /etc/frp/frpc.toml <<EOF
transport.tls.trustedCaFile = "$(esc "$TLS_CA_FILE")"
EOF
  fi

  # TLS server name for hostname verification (must match server cert CN/SAN)
  if [ -n "${TLS_SERVER_NAME:-}" ]; then
    cat >> /etc/frp/frpc.toml <<EOF
transport.tls.serverName = "$(esc "$TLS_SERVER_NAME")"
EOF
  fi

  # Include proxy definitions from conf.d
  cat >> /etc/frp/frpc.toml <<EOF

includes = ["${CONF_DIR}/*.toml"]
EOF

  chmod 400 /etc/frp/frpc.toml
  chown frp:frp /etc/frp/frpc.toml 2>/dev/null || true
}

# --- Generate config based on mode ---

if [ "$FRP_MODE" = "server" ]; then
  generate_server_config
  FRP_BIN="frps"
  FRP_CONF="/etc/frp/frps.toml"
else
  generate_client_config
  FRP_BIN="frpc"
  FRP_CONF="/etc/frp/frpc.toml"
fi

# --- Health endpoint ---

start_health_server() {
  HEALTH_DIR="/tmp/health"
  mkdir -p "$HEALTH_DIR/cgi-bin"

  cat > "$HEALTH_DIR/cgi-bin/health" <<HEALTHEOF
#!/bin/sh
if pgrep ${FRP_BIN} > /dev/null 2>&1; then
  printf 'Content-Type: text/plain\r\n\r\nok\n'
else
  printf 'Status: 503\r\nContent-Type: text/plain\r\n\r\n${FRP_BIN} not running\n'
fi
HEALTHEOF
  chmod +x "$HEALTH_DIR/cgi-bin/health"

  httpd -p "$HEALTH_PORT" -h "$HEALTH_DIR"
}

if [ -n "$HEALTH_PORT" ] && [ "$HEALTH_PORT" != "0" ]; then
  start_health_server
fi

# Drop to frp user if running as root, otherwise exec directly
if [ "$(id -u)" = "0" ]; then
  exec su-exec frp /usr/bin/${FRP_BIN} -c ${FRP_CONF}
else
  exec /usr/bin/${FRP_BIN} -c ${FRP_CONF}
fi
