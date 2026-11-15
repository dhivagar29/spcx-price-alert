#!/usr/bin/env bash
# SPCX price watcher: POST once per US trading day to a webhook when the
# last price is at or below PRICE_THRESHOLD.
#
# Env:
#   SPCX_WEBHOOK_URL, SPCX_WEBHOOK_KEY  required unless DRY_RUN=1 (never printed)
#   PRICE_THRESHOLD   default 115.00
#   FORCE_TEST        true/TRUE/1 -> POST a test payload, ignore marker/staleness, never write marker
#   DRY_RUN           1 -> print payload instead of POSTing; never write the marker
#   MARKER_DIR        default .spcx-cache
#   PRICE_OVERRIDE    use this price instead of fetching (tests); as_of is now
#   NY_TODAY          YYYY-MM-DD to treat as today's America/New_York date (tests)
#   SPCX_URL_YAHOO1 / SPCX_URL_YAHOO2 / SPCX_URL_STOOQ   source URL overrides (tests)
#   FETCH_TIMEOUT     seconds per fetch, default 8
# NOTE: never enable `set -x` in this script.
set -euo pipefail

log() { printf '%s\n' "$*"; }
err() { printf 'ERROR: %s\n' "$*" >&2; }

THRESHOLD="${PRICE_THRESHOLD:-115.00}"
MARKER_DIR="${MARKER_DIR:-.spcx-cache}"
MARKER="${MARKER_DIR}/alerted"
FETCH_TIMEOUT="${FETCH_TIMEOUT:-8}"
DRY_RUN="${DRY_RUN:-0}"
NY_TODAY="${NY_TODAY:-$(TZ=America/New_York date +%F)}"
UA='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'

URL_Y1="${SPCX_URL_YAHOO1:-https://query1.finance.yahoo.com/v8/finance/chart/SPCX?interval=1m&range=1d}"
URL_Y2="${SPCX_URL_YAHOO2:-https://query2.finance.yahoo.com/v8/finance/chart/SPCX?interval=1m&range=1d}"
URL_STOOQ="${SPCX_URL_STOOQ:-https://stooq.com/q/l/?s=spcx.us&f=sd2t2ohlcv&h&e=csv}"

case "${FORCE_TEST:-false}" in
  true | TRUE | True | 1) FORCE=1 ;;
  *) FORCE=0 ;;
esac

# Secrets: strip CR/LF, re-mask, never echo.
WEBHOOK_URL="${SPCX_WEBHOOK_URL:-}"
WEBHOOK_KEY="${SPCX_WEBHOOK_KEY:-}"
WEBHOOK_URL="${WEBHOOK_URL//$'\r'/}"; WEBHOOK_URL="${WEBHOOK_URL//$'\n'/}"
WEBHOOK_KEY="${WEBHOOK_KEY//$'\r'/}"; WEBHOOK_KEY="${WEBHOOK_KEY//$'\n'/}"
unset SPCX_WEBHOOK_URL SPCX_WEBHOOK_KEY
if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
  [ -n "$WEBHOOK_URL" ] && echo "::add-mask::${WEBHOOK_URL}"
  [ -n "$WEBHOOK_KEY" ] && echo "::add-mask::${WEBHOOK_KEY}"
fi

redact() {
  local s="$1"
  [ -n "$WEBHOOK_URL" ] && s="${s//"$WEBHOOK_URL"/[REDACTED_URL]}"
  [ -n "$WEBHOOK_KEY" ] && s="${s//"$WEBHOOK_KEY"/[REDACTED_KEY]}"
  local host="${WEBHOOK_URL#*://}"; host="${host%%[/:?#]*}"
  [ -n "$host" ] && s="${s//"$host"/[REDACTED_HOST]}"
  printf '%s' "$s"
}

is_number() { [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]; }

if [ "$DRY_RUN" != "1" ]; then
  missing=()
  [ -z "$WEBHOOK_URL" ] && missing+=(SPCX_WEBHOOK_URL)
  [ -z "$WEBHOOK_KEY" ] && missing+=(SPCX_WEBHOOK_KEY)
  if [ "${#missing[@]}" -gt 0 ]; then
    err "missing or empty secret(s): ${missing[*]} (set them as repo secrets, or use DRY_RUN=1)"
    exit 2
  fi
fi

if ! is_number "$THRESHOLD"; then
  err "PRICE_THRESHOLD is not a number: '${THRESHOLD}'"
  exit 2
fi

if [ "$FORCE" -eq 0 ] && [ -f "$MARKER" ]; then
  log "Alert already fired for this trading day (marker ${MARKER}); nothing to do."
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PRICE="" AS_OF="" SOURCE="" QUOTE_NY=""

# fetch <name> <url> -> sets HTTP_CODE, body in $TMP/body; returns non-zero on failure
fetch() {
  local name="$1" url="$2" rc=0
  HTTP_CODE="$(curl -sS -L --max-time "$FETCH_TIMEOUT" -A "$UA" \
    -H 'Accept: application/json,text/csv,*/*' \
    -o "$TMP/body" -w '%{http_code}' "$url" 2>"$TMP/curl.err")" || rc=$?
  if [ "$rc" -ne 0 ]; then
    log "source ${name}: curl error ${rc} ($(head -c 200 "$TMP/curl.err" | tr '\n' ' '))"
    return 1
  fi
  if [ "$HTTP_CODE" != "200" ]; then
    log "source ${name}: HTTP ${HTTP_CODE}"
    return 1
  fi
}

try_yahoo() {
  local name="$1" url="$2" out p ts
  fetch "$name" "$url" || return 1
  if ! out="$(jq -er '.chart.result[0].meta
        | select(.regularMarketPrice != null and .regularMarketTime != null)
        | "\(.regularMarketPrice) \(.regularMarketTime | floor)"' "$TMP/body" 2>/dev/null)"; then
    log "source ${name}: unexpected JSON (no meta.regularMarketPrice/regularMarketTime)"
    return 1
  fi
  p="${out%% *}"; ts="${out#* }"
  if ! is_number "$p" || ! [[ "$ts" =~ ^[0-9]+$ ]]; then
    log "source ${name}: price or regularMarketTime is not a number"
    return 1
  fi
  PRICE="$p"
  AS_OF="$(date -u -d "@$ts" +%Y-%m-%dT%H:%M:%SZ)"
  QUOTE_NY="$(TZ=America/New_York date -d "@$ts" +%F)"
  SOURCE="$name"
}

try_stooq() {
  local name="stooq" line close d t
  fetch "$name" "$URL_STOOQ" || return 1
  if grep -qi '<html\|<!doctype' "$TMP/body"; then
    log "source ${name}: got HTML instead of CSV"
    return 1
  fi
  # Header: Symbol,Date,Time,Open,High,Low,Close,Volume
  line="$(sed -n '2p' "$TMP/body" | tr -d '\r')"
  d="$(printf '%s' "$line" | cut -d, -f2)"
  t="$(printf '%s' "$line" | cut -d, -f3)"
  close="$(printf '%s' "$line" | cut -d, -f7)"
  if [ -z "$line" ] || [[ "$line" == *N/D* ]] || ! is_number "$close"; then
    log "source ${name}: no usable Close in CSV"
    return 1
  fi
  if ! [[ "$d" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    log "source ${name}: unusable Date column"
    return 1
  fi
  if [ -z "$t" ]; then
    t="16:00:00"
  fi
  # Stooq Date/Time are exchange-local (America/New_York for US names).
  # Convert via epoch: `date -u` would otherwise ignore TZ= and treat the clock as UTC.
  local epoch
  if ! epoch="$(TZ=America/New_York date -d "${d} ${t}" +%s)"; then
    log "source ${name}: could not parse Date/Time as America/New_York"
    return 1
  fi
  AS_OF="$(date -u -d "@$epoch" +%Y-%m-%dT%H:%M:%SZ)"
  PRICE="$close" QUOTE_NY="$d" SOURCE="$name"
}

if [ -n "${PRICE_OVERRIDE:-}" ]; then
  if ! is_number "$PRICE_OVERRIDE"; then
    err "PRICE_OVERRIDE is not a number: '${PRICE_OVERRIDE}'"
    exit 2
  fi
  PRICE="$PRICE_OVERRIDE"
  AS_OF="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  # Override quotes are "now"; freshness uses the real current NY date of as_of.
  QUOTE_NY="$(TZ=America/New_York date +%F)"
  SOURCE="override"
else
  try_yahoo yahoo-query1 "$URL_Y1" || try_yahoo yahoo-query2 "$URL_Y2" || try_stooq || {
    err "all price sources failed; not POSTing"
    exit 3
  }
fi

log "SPCX price ${PRICE} (as of ${AS_OF}, NY date ${QUOTE_NY}, source ${SOURCE}); threshold ${THRESHOLD}"

if [ "$FORCE" -eq 0 ] && [ "$QUOTE_NY" != "$NY_TODAY" ]; then
  log "Quote date ${QUOTE_NY} (America/New_York) is not today (${NY_TODAY}); skipping (no alert, no marker)."
  exit 0
fi
if [ "$FORCE" -eq 1 ] && [ "$QUOTE_NY" != "$NY_TODAY" ]; then
  log "FORCE_TEST: quote date ${QUOTE_NY} is not today (${NY_TODAY}); POSTing anyway with real as_of."
fi

AT_OR_BELOW="$(jq -n --argjson p "$PRICE" --argjson t "$THRESHOLD" '$p <= $t')"

if [ "$FORCE" -eq 0 ] && [ "$AT_OR_BELOW" != "true" ]; then
  log "Price is above threshold; no alert."
  exit 0
fi

PAYLOAD="$(jq -cn --argjson price "$PRICE" --arg as_of "$AS_OF" --arg source "$SOURCE" \
  --argjson test "$([ "$FORCE" -eq 1 ] && echo true || echo false)" \
  '{ticker: "SPCX", price: $price, as_of_utc: $as_of, source: $source}
   + (if $test then {test: true} else {} end)')"

post() {
  if [ "$DRY_RUN" = "1" ]; then
    log "DRY_RUN=1: would POST payload: ${PAYLOAD}"
    return 0
  fi
  # Pass URL and Authorization header via a private curl config file so they
  # never appear on the command line or in logs.
  local cfg="$TMP/curl.cfg" rc=0 code esc_url esc_key
  esc_url="${WEBHOOK_URL//\\/\\\\}"; esc_url="${esc_url//\"/\\\"}"
  esc_key="${WEBHOOK_KEY//\\/\\\\}"; esc_key="${esc_key//\"/\\\"}"
  (umask 077; printf 'url = "%s"\nheader = "Authorization: Bearer %s"\n' "$esc_url" "$esc_key" >"$cfg")
  code="$(printf '%s' "$PAYLOAD" | curl --fail-with-body -sS --max-time 20 -K "$cfg" \
    -X POST -H 'Content-Type: application/json' --data-binary @- \
    -o "$TMP/post.body" -w '%{http_code}' 2>"$TMP/post.err")" || rc=$?
  rm -f "$cfg"
  if [ "$rc" -ne 0 ]; then
    err "webhook POST failed (curl exit ${rc}, HTTP ${code:-000})"
    err "curl: $(redact "$(head -c 300 "$TMP/post.err" | tr '\n' ' ')")"
    [ -s "$TMP/post.body" ] && err "response: $(redact "$(head -c 300 "$TMP/post.body" | tr '\n' ' ')")"
    return 1
  fi
  log "webhook POST ok (HTTP ${code})"
}

if [ "$FORCE" -eq 1 ]; then
  log "FORCE_TEST: sending test payload (marker not written)."
  post || exit 4
  exit 0
fi

log "Price at or below threshold; alerting."
post || exit 4
if [ "$DRY_RUN" = "1" ]; then
  log "DRY_RUN=1: marker not written."
  exit 0
fi
# Only create the cache dir now, so actions/cache saves today's key only after a real alert.
mkdir -p "$MARKER_DIR"
printf '%s %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$PRICE" "$SOURCE" >"$MARKER"
log "Marker written: ${MARKER}"
