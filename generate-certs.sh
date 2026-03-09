#!/bin/sh
set -eu

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Generate TLS certificates for frp mTLS authentication.

Options:
  -s, --servers N     Number of server certificates to generate (default: 1)
  -c, --clients N     Number of client certificates to generate (default: 1)
  -d, --dir DIR       Output directory (default: ./certs)
  -a, --ca-cert FILE  Path to existing CA certificate
  -k, --ca-key FILE   Path to existing CA private key
  -b, --bits N        RSA key size in bits (default: 4096)
  -y, --years N       Certificate validity in years (default: 10)
  -h, --help          Show this help message
EOF
  exit 0
}

SERVERS=1
CLIENTS=1
OUT_DIR="./certs"
CA_CERT=""
CA_KEY=""
BITS=4096
YEARS=10

while [ $# -gt 0 ]; do
  case "$1" in
    -s|--servers) SERVERS="$2"; shift 2 ;;
    -c|--clients) CLIENTS="$2"; shift 2 ;;
    -d|--dir)     OUT_DIR="$2"; shift 2 ;;
    -a|--ca-cert) CA_CERT="$2"; shift 2 ;;
    -k|--ca-key)  CA_KEY="$2"; shift 2 ;;
    -b|--bits)    BITS="$2"; shift 2 ;;
    -y|--years)   YEARS="$2"; shift 2 ;;
    -h|--help)    usage ;;
    *) echo "Unknown option: $1" >&2; usage ;;
  esac
done

# Validate inputs
case "$SERVERS" in ''|*[!0-9]*) echo "ERROR: --servers must be a positive integer" >&2; exit 1 ;; esac
case "$CLIENTS" in ''|*[!0-9]*) echo "ERROR: --clients must be a positive integer" >&2; exit 1 ;; esac
case "$BITS" in ''|*[!0-9]*) echo "ERROR: --bits must be a positive integer" >&2; exit 1 ;; esac
case "$YEARS" in ''|*[!0-9]*) echo "ERROR: --years must be a positive integer" >&2; exit 1 ;; esac

if [ "$SERVERS" -lt 1 ] || [ "$CLIENTS" -lt 1 ]; then
  echo "ERROR: need at least 1 server and 1 client" >&2
  exit 1
fi

if [ -n "$CA_CERT" ] && [ -z "$CA_KEY" ]; then
  echo "ERROR: --ca-key is required when --ca-cert is provided" >&2
  exit 1
fi
if [ -z "$CA_CERT" ] && [ -n "$CA_KEY" ]; then
  echo "ERROR: --ca-cert is required when --ca-key is provided" >&2
  exit 1
fi

if ! command -v openssl >/dev/null 2>&1; then
  echo "ERROR: openssl is required but not found" >&2
  exit 1
fi

DAYS=$((YEARS * 365))
CURRENT_USER=$(id -u)
CURRENT_GROUP=$(id -g)

mkdir -p "$OUT_DIR"

# --- CA ---

if [ -n "$CA_CERT" ]; then
  echo "Using existing CA: $CA_CERT"
  cp "$CA_CERT" "$OUT_DIR/ca.crt"
  cp "$CA_KEY" "$OUT_DIR/ca.key"
else
  echo "Generating CA..."
  openssl genrsa -out "$OUT_DIR/ca.key" "$BITS" 2>/dev/null
  openssl req -new -x509 -days "$DAYS" -key "$OUT_DIR/ca.key" -out "$OUT_DIR/ca.crt" \
    -subj "/CN=frp-ca" 2>/dev/null
fi

chmod 600 "$OUT_DIR/ca.key"
chmod 644 "$OUT_DIR/ca.crt"

# --- Helper to generate a signed cert ---

generate_cert() {
  name="$1"
  cn="$2"

  echo "  $name"
  openssl genrsa -out "$OUT_DIR/${name}.key" "$BITS" 2>/dev/null
  openssl req -new -key "$OUT_DIR/${name}.key" -out "$OUT_DIR/${name}.csr" \
    -subj "/CN=${cn}" 2>/dev/null

  # Modern Go requires SANs (CN-only certs are rejected since Go 1.15)
  SAN_FILE=$(mktemp)
  printf "subjectAltName=DNS:%s\n" "$cn" > "$SAN_FILE"
  openssl x509 -req -days "$DAYS" \
    -in "$OUT_DIR/${name}.csr" \
    -CA "$OUT_DIR/ca.crt" -CAkey "$OUT_DIR/ca.key" -CAcreateserial \
    -extfile "$SAN_FILE" \
    -out "$OUT_DIR/${name}.crt" 2>/dev/null
  rm -f "$OUT_DIR/${name}.csr" "$SAN_FILE"

  chmod 600 "$OUT_DIR/${name}.key"
  chmod 644 "$OUT_DIR/${name}.crt"
}

# --- Server certs ---

echo "Generating $SERVERS server certificate(s)..."
i=1
while [ "$i" -le "$SERVERS" ]; do
  if [ "$SERVERS" -eq 1 ]; then
    generate_cert "server" "frps"
  else
    generate_cert "server-${i}" "frps-${i}"
  fi
  i=$((i + 1))
done

# --- Client certs ---

echo "Generating $CLIENTS client certificate(s)..."
i=1
while [ "$i" -le "$CLIENTS" ]; do
  if [ "$CLIENTS" -eq 1 ]; then
    generate_cert "client" "frpc"
  else
    generate_cert "client-${i}" "frpc-${i}"
  fi
  i=$((i + 1))
done

# --- Harden directory ---

rm -f "$OUT_DIR/ca.srl"
chown -R "${CURRENT_USER}:${CURRENT_GROUP}" "$OUT_DIR"
chmod 700 "$OUT_DIR"

echo ""
echo "Certificates generated in $OUT_DIR/"
echo ""
ls -la "$OUT_DIR"/
echo ""
echo "Server setup:"
if [ "$SERVERS" -eq 1 ]; then
  echo "  Mount ca.crt, server.crt, server.key into /etc/frp/tls/ on frps"
else
  echo "  Mount ca.crt and the matching server-N.crt/key into /etc/frp/tls/ on each frps"
fi
echo ""
echo "Client setup (frpc.toml):"
if [ "$CLIENTS" -eq 1 ]; then
  echo "  transport.tls.certFile = \"/path/to/client.crt\""
  echo "  transport.tls.keyFile = \"/path/to/client.key\""
else
  echo "  transport.tls.certFile = \"/path/to/client-N.crt\""
  echo "  transport.tls.keyFile = \"/path/to/client-N.key\""
fi
echo "  transport.tls.trustedCaFile = \"/path/to/ca.crt\""
echo ""
echo "Keep ca.key safe -- it is only needed to sign new certificates."
