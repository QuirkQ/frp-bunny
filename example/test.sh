#!/bin/sh
set -eu

apk add --no-cache curl > /dev/null 2>&1

# ── serverAddr re-resolution ───────────────────────────────────────
#
# The stack starts with frps.test.internal pointing at an address
# nothing listens on, so frpc's SERVER_ADDR resolves to a black hole and
# it cannot log in. Repointing the name at the real frps is the test:
# the chain has to come up with nobody touching frpc — no restart, no
# config change, no redeploy.
#
# That is the property a hostname-based SERVER_ADDR rests on. frpc hands
# the ServerAddr string to the dialer on every login attempt rather than
# resolving once at startup, so when the server's address moves,
# updating DNS is the whole recovery. Pinning an IP in config instead
# makes the same event a manual edit-and-redeploy.

echo "Checking frpc starts out misdirected..."
MISDIRECTED=0
for i in $(seq 1 30); do
  if nslookup frps.test.internal 172.20.0.2 2>/dev/null | grep -q "172.20.1.99"; then
    MISDIRECTED=1
    break
  fi
  sleep 1
done

# Without this the repoint below could land before CoreDNS ever served
# the black hole, and the recovery test would pass without frpc having
# been misdirected at all.
if [ "$MISDIRECTED" = "0" ]; then
  echo "FAIL: frps.test.internal never resolved to the black hole"
  echo "      address, so the re-resolution test cannot prove anything."
  exit 1
fi

if curl -sk --max-time 3 https://app.test.internal 2>/dev/null | grep -q "nginx"; then
  echo "FAIL: the chain is serving while frpc is pointed at a black"
  echo "      hole — something other than frpc is routing this traffic."
  exit 1
fi

echo "Repointing frps.test.internal at the live frps..."
sed -i 's/^172\.20\.1\.99 frps\.test\.internal$/172.20.1.10 frps.test.internal/' /dns/hosts
if ! grep -q '^172\.20\.1\.10 frps\.test\.internal$' /dns/hosts; then
  echo "FAIL: could not rewrite /dns/hosts"
  exit 1
fi

# ── Wait for DNS + full chain: test → DNS → frps → frpc → caddy → app ──
#
# Generous budget: frpc has to notice the black hole is gone on its own
# schedule (login retry backoff, or the supervisor restarting it after
# repeated health failures — either path re-resolves).

echo "Waiting for end-to-end chain..."
READY=0
for i in $(seq 1 90); do
  if curl -sk https://app.test.internal 2>/dev/null | grep -q "nginx"; then
    READY=1
    break
  fi
  sleep 1
done

if [ "$READY" = "0" ]; then
  echo "FAIL: frpc did not follow the repointed serverAddr within 90s"
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

# The repoint above is actually being served
run_test "frps name repointed in DNS" \
  sh -c 'nslookup frps.test.internal 172.20.0.2 2>/dev/null | grep -q "172.20.1.10"'

# ...and frpc found the server at its new address on its own. Recorded
# here so the summary states the property; the run aborts above if it
# never recovered, since every test below it would fail as a cascade.
run_test "serverAddr followed DNS repoint" \
  sh -c "[ '$READY' = '1' ]"

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
