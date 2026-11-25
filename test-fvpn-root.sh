#!/bin/bash
# Tests for the root helper embedded in fvpn-setup.sh (up/down process handling).
#
# The helper is extracted from fvpn-setup.sh, repointed at a fake openfortivpn and a
# fake `ifconfig ppp0`, and exercised as the normal user: no root, no gateway, no
# FortiToken. What is tested is the logic deciding "already connected", "previous tunnel
# still shutting down", "another up is in flight", and how long `down` waits before it
# may claim success.
#
#   bash test-fvpn-root.sh              # everything (~3 min: two 60s teardown cases)
#   SKIP_SLOW=1 bash test-fvpn-root.sh  # skip the two 60s cases (~1 min)
set -u
SRC=$(cd "$(dirname "$0")" && pwd)/fvpn-setup.sh
E2E=$(mktemp -d /tmp/fvpn-root-test.XXXXXX)
fail=0
ok()  { echo "   PASS $*"; }
bad() { echo "   FAIL $*"; fail=1; }
alive() { /bin/kill -0 "$1" 2>/dev/null; }
scrub() { pkill -9 -f "$E2E/openfortivpn" 2>/dev/null; sleep 0.3; }
trap 'scrub; rm -rf "$E2E"' EXIT

echo "== building the sandbox in $E2E =="
mkdir -p "$E2E/conf"

cat > "$E2E/ifconfig" <<EOF
#!/bin/bash
# fake ppp0: present only while the marker file exists
case "\$1" in -l) echo "lo0 en0 ppp0"; exit 0 ;; esac
[ "\$1" = ppp0 ] && [ -f $E2E/ppp0_up ] || exit 1
printf 'ppp0: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1354\n\tinet 10.20.72.99 --> 169.254.2.1 netmask 0xff000000\n'
EOF

cat > "$E2E/openfortivpn" <<EOF
#!/bin/bash
# fake openfortivpn; argv carries "-c <conf>" like the real one:
#   SLOW_EXIT=0      terminate is ignored forever
#   SLOW_EXIT=N      N seconds of teardown after SIGTERM, then it exits
#   FAKE_LIFETIME=N  it exits by itself after N seconds (a tunnel already tearing down)
cleanup() { rm -f $E2E/ppp0_up; exit 0; }
on_term() { [ "\${SLOW_EXIT:--1}" = 0 ] && return 0; sleep "\${SLOW_EXIT:--1}"; cleanup; }
trap on_term TERM INT
[ "\${CREATE_PPP0:-0}" = 1 ] && : > $E2E/ppp0_up
deadline=0
[ -n "\${FAKE_LIFETIME:-}" ] && deadline=\$(( \$(/bin/date +%s) + FAKE_LIFETIME ))
sleep 600 &
while :; do
  sleep 0.2
  [ "\$deadline" != 0 ] && [ "\$(/bin/date +%s)" -ge "\$deadline" ] && cleanup
done
EOF
: > "$E2E/pinentry"
chmod +x "$E2E/ifconfig" "$E2E/openfortivpn" "$E2E/pinentry"
printf 'host = vpn-test.internetbrands.com\nuser = test\n' > "$E2E/conf/test.conf"

# the helper is embedded in a quoted heredoc: extract it exactly as setup does
awk '/^cat > "\$TMP\/fvpn-root" <<.EOS./{f=1;next} f&&/^EOS$/{exit} f' "$SRC" > "$E2E/root.raw"
FVPN_GW_PREFIX=vpn- FVPN_GW_DOMAIN=internetbrands.com \
  /usr/bin/perl -pe 's/__PREFIX__/$ENV{FVPN_GW_PREFIX}/g; s/__DOMAIN__/$ENV{FVPN_GW_DOMAIN}/g' \
  "$E2E/root.raw" > "$E2E/root"
# repoint it at the sandbox: no root-owned paths, no real ppp0, no real intent file
sed -i '' \
  -e "s#^CONFDIR=/usr/local/etc/openfortivpn#CONFDIR=$E2E/conf#" \
  -e "s#^OFP=/usr/local/libexec/fvpn/openfortivpn#OFP=$E2E/openfortivpn#" \
  -e "s#^PINENTRY=/usr/local/libexec/fvpn-pinentry#PINENTRY=$E2E/pinentry#" \
  -e "s#^OFP_DIR=/usr/local/libexec/fvpn#OFP_DIR=$E2E#" \
  -e "s#^INTENT=/var/log/fvpn-intent#INTENT=$E2E/intent#" \
  -e "s#/var/log/fvpn-#$E2E/fvpn-#g" \
  -e "s#verify_root_files || exit 1#true#" \
  -e "s#/sbin/ifconfig#$E2E/ifconfig#g" "$E2E/root"
chmod +x "$E2E/root"
bash -n "$E2E/root" || { echo "extracted helper has a syntax error"; exit 1; }

start_fake() { env "$@" "$E2E/openfortivpn" -c "$E2E/conf/test.conf" --pinentry=x >/dev/null 2>&1 & echo $!; }
reset() { scrub; rm -f "$E2E/ppp0_up"; echo "down - $(/bin/date +%s)" > "$E2E/intent"; }

echo "== up: a tunnel that is already tearing down is waited for, not reported as success =="
reset
pid=$(start_fake SLOW_EXIT=30 FAKE_LIFETIME=6); sleep 0.5
t0=$(/bin/date +%s)
out=$(CREATE_PPP0=1 "$E2E/root" up test 15 2>&1); rc=$?
el=$(( $(/bin/date +%s) - t0 ))
echo "   rc=$rc ${el}s: $(echo "$out" | tr '\n' '|')"
[ $rc = 0 ] && ok "exits 0 only after it really connected" || bad "rc=$rc when it did connect"
echo "$out" | grep -q 'still shutting down' && ok "announces the wait" || bad "no wait message"
echo "$out" | grep -q '^test: up' && ok "connects once the ghost is gone" || bad "never connected"
echo "$out" | grep -q 'already running' && bad "still prints the old 'already running' + exit 0" || ok "no silent no-op"
[ "$el" -ge 4 ] && ok "actually waited for the ghost (${el}s)" || bad "did not wait (${el}s)"

echo "== up: a live tunnel is reported as connected, without spawning a second one =="
before=$(pgrep -f "$E2E/openfortivpn" | wc -l | tr -d ' ')
out=$(CREATE_PPP0=1 "$E2E/root" up test 15 2>&1); rc=$?
after=$(pgrep -f "$E2E/openfortivpn" | wc -l | tr -d ' ')
[ $rc = 0 ] && echo "$out" | grep -q 'already connected' && ok "'already connected', rc=0" || bad "misbehaved on a live tunnel"
[ "$before" = "$after" ] && ok "no extra openfortivpn" || bad "started a second tunnel"

echo "== up: refuses to fight another up that is still awaiting approval =="
reset
pid=$(start_fake SLOW_EXIT=30); sleep 0.5
now=$(/bin/date +%s); printf 'up test %s %s\n' "$now" "$(( now + 45 ))" > "$E2E/intent"
out=$("$E2E/root" up test 15 2>&1); rc=$?
[ $rc = 1 ] && echo "$out" | grep -q 'still in progress' && ok "exit 1 with a clear message" || bad "did not refuse cleanly (rc=$rc)"
alive "$pid" && ok "the tunnel still authenticating was left alone" || bad "killed a tunnel awaiting approval"

echo "== up: a ppp0 that is not ours is still refused =="
reset; : > "$E2E/ppp0_up"
out=$("$E2E/root" up test 15 2>&1); rc=$?
[ $rc = 1 ] && echo "$out" | grep -q 'ERROR: ppp0 already exists' && ok "says ppp0 belongs to someone else" || bad "claimed 'already connected' on a foreign ppp0"

echo "== down: waits out a real teardown, and keeps it graceful =="
reset
pid=$(start_fake SLOW_EXIT=14); : > "$E2E/ppp0_up"; sleep 0.5
t0=$(/bin/date +%s)
out=$("$E2E/root" down test 2>&1); rc=$?
el=$(( $(/bin/date +%s) - t0 ))
echo "   rc=$rc ${el}s: $(echo "$out" | tr '\n' '|')"
! alive "$pid" && ok "waited for the real exit (${el}s) before saying 'down'" || bad "said 'down' while the tunnel was alive"
echo "$out" | grep -q 'sending SIGKILL' && bad "escalated a 14s teardown to SIGKILL" || ok "stayed graceful"
[ $rc = 0 ] && echo "$out" | grep -q 'test: down' && ok "rc=0 with 'test: down'" || bad "rc=$rc on a clean teardown"

if [ "${SKIP_SLOW:-0}" = 1 ]; then
  echo "== skipped: the two 60s teardown cases (SKIP_SLOW=1) =="
else
  echo "== up: gives up, and says so, when the ghost ignores SIGTERM =="
  reset
  pid=$(start_fake SLOW_EXIT=0); sleep 0.5
  out=$("$E2E/root" up test 15 2>&1); rc=$?
  [ $rc = 1 ] && echo "$out" | grep -q 'still there after 60s' && ok "fails with an actionable message" || bad "did not fail as intended (rc=$rc)"
  alive "$pid" && ok "no SIGKILL from up (route restore must not be cut short)" || bad "up killed a stubborn ghost"

  echo "== down: escalates to SIGKILL and stops pretending =="
  reset
  pid=$(start_fake SLOW_EXIT=0); : > "$E2E/ppp0_up"; sleep 0.5
  out=$("$E2E/root" down test 2>&1); rc=$?
  echo "$out" | grep -q 'sending SIGKILL' && ok "escalation announced" || bad "no escalation"
  ! alive "$pid" && ok "the stubborn tunnel was killed" || bad "survived SIGKILL"
  [ $rc = 1 ] && echo "$out" | grep -q 'WARNING: ppp0 still exists' && ok "warns instead of claiming success" || bad "pretended the teardown worked"
fi

echo "== down: idle host =="
reset
out=$("$E2E/root" down test 2>&1); rc=$?
[ $rc = 0 ] && echo "$out" | grep -q 'not running' && ok "'not running', rc=0" || bad "misbehaved on an idle host"

echo
if [ $fail = 0 ]; then echo "passed: all helper checks"; else echo "failed: see FAIL lines above"; fi
exit $fail
