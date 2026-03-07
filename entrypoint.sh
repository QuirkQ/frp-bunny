#!/bin/sh
set -eu

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
MAX_PORTS_PER_CLIENT="${MAX_PORTS_PER_CLIENT:-5}"

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

if ! is_uint "$MAX_PORTS_PER_CLIENT"; then
  echo "ERROR: MAX_PORTS_PER_CLIENT must be a non-negative integer, got: $MAX_PORTS_PER_CLIENT" >&2
  exit 1
fi

# Escape strings for safe TOML embedding (backslashes then double quotes)
esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# --- Generate config ---

cat > /etc/frp/frps.toml <<EOF
bindAddr = "0.0.0.0"
bindPort = ${BIND_PORT}

auth.token = "$(esc "$FRP_TOKEN")"

# Require TLS between frpc and frps
transport.tls.force = true

# Limit attack surface from a compromised token
maxPortsPerClient = ${MAX_PORTS_PER_CLIENT}
detailedErrorsToClient = false
EOF

# Dashboard: only enabled when DASHBOARD_PASSWORD is set
if [ -n "${DASHBOARD_PASSWORD:-}" ]; then
  cat >> /etc/frp/frps.toml <<EOF

webServer.addr = "0.0.0.0"
webServer.port = ${DASHBOARD_PORT}
webServer.user = "$(esc "${DASHBOARD_USER:-admin}")"
webServer.password = "$(esc "$DASHBOARD_PASSWORD")"
EOF
fi

# Vhost ports: only enabled when explicitly set
if [ -n "${VHOST_HTTP_PORT:-}" ]; then
  echo "vhostHTTPPort = ${VHOST_HTTP_PORT}" >> /etc/frp/frps.toml
fi
if [ -n "${VHOST_HTTPS_PORT:-}" ]; then
  echo "vhostHTTPSPort = ${VHOST_HTTPS_PORT}" >> /etc/frp/frps.toml
fi

chmod 400 /etc/frp/frps.toml

exec /usr/bin/frps -c /etc/frp/frps.toml
