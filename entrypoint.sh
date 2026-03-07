#!/bin/sh
set -eu

# --- User setup ---

PUID="${PUID:-1000}"
PGID="${PGID:-1000}"

setup_user() {
  CUR_UID=$(id -u frps)
  CUR_GID=$(id -g frps)

  if [ "$CUR_GID" != "$PGID" ]; then
    sed -i "s/^frps:x:${CUR_GID}:/frps:x:${PGID}:/" /etc/group
    sed -i "s/^\(frps:[^:]*:[^:]*:\)${CUR_GID}:/\1${PGID}:/" /etc/passwd
  fi

  if [ "$CUR_UID" != "$PUID" ]; then
    sed -i "s/^frps:\([^:]*\):${CUR_UID}:/frps:\1:${PUID}:/" /etc/passwd
  fi

  chown frps:frps /etc/frp
}

# Adjust UID/GID if running as root
if [ "$(id -u)" = "0" ]; then
  setup_user
fi

# --- Validation ---

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

BIND_PORT="${BIND_PORT:-7000}"
DASHBOARD_PORT="${DASHBOARD_PORT:-7500}"
DASHBOARD_ADDR="${DASHBOARD_ADDR:-127.0.0.1}"
MAX_PORTS_PER_CLIENT="${MAX_PORTS_PER_CLIENT:-5}"
MAX_POOL_COUNT="${MAX_POOL_COUNT:-5}"
ALLOW_PORTS="${ALLOW_PORTS:-10000-50000}"

PORT_VARS="BIND_PORT DASHBOARD_PORT"

# Vhost ports are optional — only validated/enabled if explicitly set
if [ -n "${VHOST_HTTP_PORT:-}" ]; then
  PORT_VARS="$PORT_VARS VHOST_HTTP_PORT"
fi
if [ -n "${VHOST_HTTPS_PORT:-}" ]; then
  PORT_VARS="$PORT_VARS VHOST_HTTPS_PORT"
fi

for var in $PORT_VARS; do
  eval val=\$$var
  if ! is_port "$val"; then
    echo "ERROR: $var must be a valid port number (1-65535), got: $val" >&2
    exit 1
  fi
done

for var in MAX_PORTS_PER_CLIENT MAX_POOL_COUNT; do
  eval val=\$$var
  if ! is_uint "$val"; then
    echo "ERROR: $var must be a non-negative integer, got: $val" >&2
    exit 1
  fi
done

# Escape strings for safe TOML embedding (backslashes then double quotes)
esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

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

# --- Generate config ---

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

# Restrict which ports clients may bind
build_allow_ports "$ALLOW_PORTS" >> /etc/frp/frps.toml

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

# Vhost ports: only enabled when explicitly set
if [ -n "${VHOST_HTTP_PORT:-}" ]; then
  echo "vhostHTTPPort = ${VHOST_HTTP_PORT}" >> /etc/frp/frps.toml
fi
if [ -n "${VHOST_HTTPS_PORT:-}" ]; then
  echo "vhostHTTPSPort = ${VHOST_HTTPS_PORT}" >> /etc/frp/frps.toml
fi

# Subdomain restriction: only when explicitly set
if [ -n "${SUBDOMAIN_HOST:-}" ]; then
  echo "subDomainHost = \"$(esc "$SUBDOMAIN_HOST")\"" >> /etc/frp/frps.toml
fi

chmod 400 /etc/frp/frps.toml
chown frps:frps /etc/frp/frps.toml 2>/dev/null || true

# Drop to frps user if running as root, otherwise exec directly
if [ "$(id -u)" = "0" ]; then
  exec su-exec frps /usr/bin/frps -c /etc/frp/frps.toml
else
  exec /usr/bin/frps -c /etc/frp/frps.toml
fi
