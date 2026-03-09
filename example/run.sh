#!/bin/sh
set -eu

cd "$(dirname "$0")"

BUILD=true
if [ "${1:-}" = "--no-build" ]; then
  BUILD=false
fi

CERTS_VOL="example_certs"

cleanup() {
  echo ""
  echo "Cleaning up..."
  docker compose down --remove-orphans 2>/dev/null || true
  docker volume rm "$CERTS_VOL" 2>/dev/null || true
}
trap cleanup EXIT

# ── Generate mTLS certs ──────────────────────────────────────────

if ! docker volume inspect "$CERTS_VOL" > /dev/null 2>&1; then
  echo "Generating mTLS certificates..."
  docker volume create "$CERTS_VOL" > /dev/null
  docker run --rm \
    -v "$CERTS_VOL":/certs \
    -v "$(cd .. && pwd)/generate-certs.sh":/generate-certs.sh:ro \
    alpine:3.23 sh -c \
    "apk add --no-cache openssl > /dev/null 2>&1 && sh /generate-certs.sh -d /certs -b 2048 -y 1 && chown -R 1000:1000 /certs"
fi

# ── Build ─────────────────────────────────────────────────────────

if [ "$BUILD" = "true" ]; then
  echo "Building image..."
  docker compose build --quiet
fi

# ── Run ───────────────────────────────────────────────────────────

echo "Starting services..."
docker compose up --exit-code-from test --abort-on-container-exit
