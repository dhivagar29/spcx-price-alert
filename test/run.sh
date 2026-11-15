#!/usr/bin/env bash
# Local tests for scripts/check.sh. Never touches the real webhook or network
# (all URLs point at a 127.0.0.1 stub).
# SC2016: assertions are single-quoted on purpose; check() evals them later.
# shellcheck disable=SC2016
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT/scripts/check.sh"
WORK="$(mktemp -d)"
PORTFILE="$WORK/port"
REQLOG="$WORK/requests.jsonl"
KEY="local-test-value"
PASS=0 FAIL=0

python3 -I "$ROOT/test/listener.py" "$PORTFILE" "$REQLOG" &
LPID=$!
trap 'kill "$LPID" 2>/dev/null; rm -rf "$WORK"' EXIT
for _ in $(seq 50); do [ -s "$PORTFILE" ] && break; sleep 0.1; done
PORT="$(cat "$PORTFILE")"
BASE="http://127.0.0.1:${PORT}"
HOOK="${BASE}/hook/local-test-path"
DEAD="http://127.0.0.1:1/nothing"

ok() { PASS=$((PASS + 1)); printf 'ok   - %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL - %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }
check() { if eval "$2"; then ok "$1"; else bad "$1" "${3:-}"; fi; }

posts() { [ -f "$REQLOG" ] && jq -s '[.[] | select(.method=="POST")] | length' "$REQLOG" || echo 0; }
last_post() { jq -s '[.[] | select(.method=="POST")] | last' "$REQLOG"; }

# run <name> [VAR=val ...] : fresh marker dir + request log, captures RC and OUT
run() {
  local name="$1"; shift
  : >"$REQLOG"
  MD="$WORK/marker-$name"; rm -rf "$MD"
  [ -n "${PRESEED:-}" ] && { mkdir -p "$MD"; echo seeded >"$MD/alerted"; }
  OUT="$(env -i PATH="$PATH" HOME="$HOME" MARKER_DIR="$MD" FETCH_TIMEOUT=3 \
    SPCX_URL_YAHOO1="$DEAD" SPCX_URL_YAHOO2="$DEAD" SPCX_URL_STOOQ="$DEAD" \
    "$@" bash "$CHECK" 2>&1)"
  RC=$?
  printf '\n# %s (rc=%s)\n%s\n' "$name" "$RC" "    ${OUT//$'\n'/$'\n'    }"
}

no_secrets() { ! grep -q -e "$KEY" -e "local-test-path" <<<"$OUT"; }

echo "== 1. below threshold -> one POST with correct body/header, marker written"
run below SPCX_WEBHOOK_URL="$HOOK" SPCX_WEBHOOK_KEY="$KEY" PRICE_OVERRIDE=100.50
check "exit 0" '[ "$RC" -eq 0 ]'
check "exactly 1 POST" '[ "$(posts)" -eq 1 ]'
P="$(last_post)"
check "POST path is webhook" '[ "$(jq -r .path <<<"$P")" = "/hook/local-test-path" ]'
check "Authorization: Bearer <key>" '[ "$(jq -r ".headers.Authorization" <<<"$P")" = "Bearer $KEY" ]'
check "Content-Type json" '[ "$(jq -r ".headers[\"Content-Type\"]" <<<"$P")" = "application/json" ]'
B="$(jq -r .body <<<"$P")"
check "body fields" 'jq -e ".ticker==\"SPCX\" and .price==100.5 and .source==\"override\" and (.as_of_utc|test(\"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$\"))" <<<"$B" >/dev/null' "$B"
check "no test key in body" 'jq -e "has(\"test\")|not" <<<"$B" >/dev/null'
check "price is a JSON number" 'jq -e ".price|type==\"number\"" <<<"$B" >/dev/null'
check "marker written" '[ -f "$MD/alerted" ]'
check "no secrets in output" no_secrets

echo "== 1b. price exactly at threshold -> POST"
run equal SPCX_WEBHOOK_URL="$HOOK" SPCX_WEBHOOK_KEY="$KEY" PRICE_OVERRIDE=115 PRICE_THRESHOLD=115.00
check "exit 0 and 1 POST" '[ "$RC" -eq 0 ] && [ "$(posts)" -eq 1 ]'

echo "== 1c. secrets with trailing CR/LF are stripped"
run crlf SPCX_WEBHOOK_URL="$HOOK"$'\r\n' SPCX_WEBHOOK_KEY="$KEY"$'\n' PRICE_OVERRIDE=100
check "exit 0, header clean" '[ "$RC" -eq 0 ] && [ "$(last_post | jq -r .headers.Authorization)" = "Bearer $KEY" ]'

echo "== 2. above threshold -> no POST, no marker"
run above SPCX_WEBHOOK_URL="$HOOK" SPCX_WEBHOOK_KEY="$KEY" PRICE_OVERRIDE=130
check "exit 0" '[ "$RC" -eq 0 ]'
check "0 POSTs" '[ "$(posts)" -eq 0 ]'
check "no marker dir created" '[ ! -e "$MD" ]'
check "says above threshold" 'grep -q "above threshold" <<<"$OUT"'

echo "== 3. FORCE_TEST=true with high price -> POST with test:true, no marker"
run force SPCX_WEBHOOK_URL="$HOOK" SPCX_WEBHOOK_KEY="$KEY" PRICE_OVERRIDE=999 FORCE_TEST=true
check "exit 0" '[ "$RC" -eq 0 ]'
check "exactly 1 POST" '[ "$(posts)" -eq 1 ]'
check "body test:true" '[ "$(last_post | jq -r .body | jq .test)" = "true" ]'
check "no marker dir created" '[ ! -e "$MD" ]'

echo "== 3b. FORCE_TEST=1 bypasses an existing marker and leaves it untouched"
PRESEED=1 run force-marker SPCX_WEBHOOK_URL="$HOOK" SPCX_WEBHOOK_KEY="$KEY" PRICE_OVERRIDE=999 FORCE_TEST=1
check "exit 0 and 1 POST" '[ "$RC" -eq 0 ] && [ "$(posts)" -eq 1 ]'
check "marker unchanged" '[ "$(cat "$MD/alerted")" = seeded ]'

echo "== 3c. FORCE_TEST with failing webhook -> non-zero, no marker"
run force-fail SPCX_WEBHOOK_URL="$BASE/fail" SPCX_WEBHOOK_KEY="$KEY" PRICE_OVERRIDE=999 FORCE_TEST=TRUE
check "non-zero exit" '[ "$RC" -ne 0 ]'
check "no marker dir created" '[ ! -e "$MD" ]'

echo "== 4. marker present, no force -> exit 0, no fetch, no POST"
PRESEED=1 run marker SPCX_WEBHOOK_URL="$HOOK" SPCX_WEBHOOK_KEY="$KEY" PRICE_OVERRIDE=50 \
  SPCX_URL_YAHOO1="$BASE/yahoo-ok"
check "exit 0" '[ "$RC" -eq 0 ]'
check "no requests at all" '[ ! -s "$REQLOG" ]'
check "says already fired" 'grep -q "already fired" <<<"$OUT"'

echo "== 5. missing secrets (not DRY_RUN) -> non-zero, no values printed"
run nosecrets PRICE_OVERRIDE=50
check "non-zero exit" '[ "$RC" -ne 0 ]'
check "names both secrets" 'grep -q SPCX_WEBHOOK_URL <<<"$OUT" && grep -q SPCX_WEBHOOK_KEY <<<"$OUT"'
check "0 POSTs" '[ "$(posts)" -eq 0 ]'
run nokey SPCX_WEBHOOK_URL="$HOOK" SPCX_WEBHOOK_KEY="" PRICE_OVERRIDE=50
check "empty key -> non-zero" '[ "$RC" -ne 0 ]'
check "URL not printed" no_secrets
run nourl SPCX_WEBHOOK_KEY="$KEY" PRICE_OVERRIDE=50
check "missing URL -> non-zero, key not printed" '[ "$RC" -ne 0 ] && no_secrets'

echo "== 6. all sources fail -> non-zero, no POST"
run fetchfail SPCX_WEBHOOK_URL="$HOOK" SPCX_WEBHOOK_KEY="$KEY" \
  SPCX_URL_YAHOO1="$BASE/404" SPCX_URL_YAHOO2="$DEAD" SPCX_URL_STOOQ="$BASE/html"
check "non-zero exit" '[ "$RC" -ne 0 ]'
check "0 POSTs" '[ "$(posts)" -eq 0 ]'
check "logs each source failure" 'grep -q "yahoo-query1: HTTP 404" <<<"$OUT" && grep -q "yahoo-query2: curl error" <<<"$OUT" && grep -q "stooq: got HTML" <<<"$OUT"'
check "no marker" '[ ! -e "$MD" ]'
run stooqnd SPCX_WEBHOOK_URL="$HOOK" SPCX_WEBHOOK_KEY="$KEY" SPCX_URL_STOOQ="$BASE/stooq-nd"
check "stooq N/D -> non-zero, 0 POSTs" '[ "$RC" -ne 0 ] && [ "$(posts)" -eq 0 ]'

echo "== 7. fallback chain picks the source that produced the price"
run y2 SPCX_WEBHOOK_URL="$HOOK" SPCX_WEBHOOK_KEY="$KEY" SPCX_URL_YAHOO1="$BASE/404" SPCX_URL_YAHOO2="$BASE/yahoo-ok"
check "yahoo-query2 used, POST sent" '[ "$RC" -eq 0 ] && [ "$(last_post | jq -r .body | jq -r .source)" = yahoo-query2 ]'
check "as_of_utc from regularMarketTime" '[ "$(last_post | jq -r .body | jq -r .as_of_utc)" = 2025-11-14T17:00:00Z ]'
check "price from meta" '[ "$(last_post | jq -r .body | jq .price)" = 101.25 ]'
run y1 SPCX_WEBHOOK_URL="$HOOK" SPCX_WEBHOOK_KEY="$KEY" SPCX_URL_YAHOO1="$BASE/yahoo-ok"
check "yahoo-query1 used" '[ "$(last_post | jq -r .body | jq -r .source)" = yahoo-query1 ]'
run st SPCX_WEBHOOK_URL="$HOOK" SPCX_WEBHOOK_KEY="$KEY" SPCX_URL_STOOQ="$BASE/stooq-ok"
check "stooq used, price 103.5" '[ "$RC" -eq 0 ] && [ "$(last_post | jq -r .body | jq -c "[.source,.price]")" = "[\"stooq\",103.5]" ]'

echo "== 8. webhook failure (non-test) -> non-zero, no marker, URL redacted"
run postfail SPCX_WEBHOOK_URL="$BASE/fail" SPCX_WEBHOOK_KEY="$KEY" PRICE_OVERRIDE=50
check "non-zero exit" '[ "$RC" -ne 0 ]'
check "no marker" '[ ! -e "$MD" ]'
check "URL/key not printed" '! grep -q -e "$BASE/fail" -e "$KEY" <<<"$OUT"'

run postconn SPCX_WEBHOOK_URL="http://127.0.0.1:1/hook/local-test-path" SPCX_WEBHOOK_KEY="$KEY" PRICE_OVERRIDE=50
check "connect error -> non-zero, no marker" '[ "$RC" -ne 0 ] && [ ! -e "$MD" ]'
check "connect error output redacted" 'no_secrets && ! grep -q "127.0.0.1" <<<"$OUT" && grep -q REDACTED_HOST <<<"$OUT"'

echo "== 9. DRY_RUN=1 without secrets prints payload, no POST"
run dry DRY_RUN=1 PRICE_OVERRIDE=90
check "exit 0, payload printed, 0 POSTs" '[ "$RC" -eq 0 ] && grep -q "would POST payload" <<<"$OUT" && [ "$(posts)" -eq 0 ]'

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
