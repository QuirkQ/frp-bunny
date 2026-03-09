#!/bin/sh
set -eu

apk add --no-cache curl > /dev/null 2>&1

# ── Wait for DNS + full chain: test → DNS → frps → frpc → caddy → app ──

echo "Waiting for end-to-end chain..."
READY=0
for i in $(seq 1 30); do
  if curl -sk https://app.test.internal 2>/dev/null | grep -q "nginx"; then
    READY=1
    break
  fi
  sleep 1
done

if [ "$READY" = "0" ]; then
  echo "FAIL: chain did not become ready within 30s"
  exit 1
fi

PASS=0
FAIL=0

run_test() {
  name="$1"
  shift
  printf "  %-40s" "$name"
  if "$@"; then
    echo "PASS"
    PASS=$((PASS + 1))
  else
    echo "FAIL"
    FAIL=$((FAIL + 1))
  fi
}

# ── Tests ──────────────────────────────────────────────────────────

echo ""
echo "Running tests..."
echo ""

# DNS resolves app.test.internal to frps
run_test "DNS resolution" \
  sh -c 'nslookup app.test.internal 172.20.0.2 2>/dev/null | grep -q "172.20.0.10"'

# HTTPS vhost: test → frps:443 (SNI) → frpc → caddy:443 → nginx
run_test "HTTPS vhost (SNI passthrough)" \
  sh -c 'curl -sk https://app.test.internal | grep -q "nginx"'

# HTTP vhost: test → frps:80 (Host header) → frpc → caddy:80
# Caddy redirects HTTP to HTTPS, so expect a 3xx
run_test "HTTP vhost (redirect)" \
  sh -c '
    code=$(curl -s -o /dev/null -w "%{http_code}" http://app.test.internal)
    [ "$code" = "308" ] || [ "$code" = "301" ] || [ "$code" = "302" ]
  '

# Server health endpoint
run_test "Server health endpoint" \
  sh -c 'curl -sf http://172.20.0.10:8080/cgi-bin/health | grep -q "ok"'

# PROXY protocol: Caddy should see the real client IP (this test runner), not the frpc IP
run_test "PROXY protocol (real client IP)" \
  sh -c 'curl -ski https://app.test.internal | grep -qi "x-real-ip: 172.20.0.100"'

# Wrong domain should not route (frps has no proxy for it)
run_test "Unknown domain rejected" \
  sh -c '
    code=$(curl -sk -o /dev/null -w "%{http_code}" --resolve nope.test.internal:443:172.20.0.10 https://nope.test.internal 2>/dev/null)
    [ "$code" = "000" ] || [ "$code" = "404" ] || [ "$code" = "502" ]
  '

# ── Summary ────────────────────────────────────────────────────────

echo ""
echo "$PASS passed, $FAIL failed"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
