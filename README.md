# spcx-price-alert

A GitHub Actions job that watches the **SPCX** (SpaceX, NASDAQ) last price. When the price is **at or below 115.00 USD** (`PRICE_THRESHOLD`), it POSTs once per US trading day to a Cursor / Grok Bot routine webhook.

## Schedule (UTC, weekdays only)

```
30 13-20 * * 1-5   # hourly at :30, 13:30–20:30 UTC
0 21 * * 1-5       # 21:00 UTC, just after the US cash close
```

Also `workflow_dispatch` (manual run, see below).

## How it decides

1. The job computes today's date in `America/New_York` and restores the cache key `spcx-alert-<YYYY-MM-DD>` (path `.spcx-cache/`, no `restore-keys`).
2. If `.spcx-cache/alerted` exists, today's alert already fired. The job exits without fetching anything.
3. Otherwise it fetches the price. If the quote's America/New_York date is not today (yesterday's close before the cash open, or a weekday market holiday), it exits 0 without POSTing or writing a marker.
4. If `price <= PRICE_THRESHOLD`, it POSTs. The marker is written **only after a successful real POST**, so `actions/cache` saves today's key only then. Runs that skip the alert, fail, dry-run, or are force tests never create `.spcx-cache/`, so they save nothing.

`force_test` still POSTs even when the quote is stale, and the payload keeps the real `as_of_utc`. GitHub cron can run several minutes late; the times above are not exact.

To change the threshold, set a repository **variable** `PRICE_THRESHOLD`, e.g. `110.00`. The default is `115.00`.

## Price sources (in order)

1. `query1.finance.yahoo.com/v8/finance/chart/SPCX?interval=1m&range=1d`: `meta.regularMarketPrice` / `meta.regularMarketTime`
2. The same path on `query2.finance.yahoo.com`
3. Stooq CSV `stooq.com/q/l/?s=spcx.us&f=sd2t2ohlcv&h&e=csv`: Close column; `as_of_utc` comes from the Date and Time columns interpreted as America/New_York (HTML, `N/D` and 404 are skipped)

Requests use a browser User-Agent. Each fetch times out after 8 s. If all three fail, the run fails and nothing is POSTed. The payload's `source` field names the source that produced the price.

## Secrets

| Name | Value |
|---|---|
| `SPCX_WEBHOOK_URL` | the routine's webhook URL |
| `SPCX_WEBHOOK_KEY` | the routine's API key |

Dhivagar copies the URL and key from the routine panel into **Settings → Secrets and variables → Actions**. This repo does not set them. The values are masked and never printed.

## Request

```
POST <SPCX_WEBHOOK_URL>
Authorization: Bearer <SPCX_WEBHOOK_KEY>
Content-Type: application/json

{"ticker":"SPCX","price":112.34,"as_of_utc":"2026-11-16T15:30:00Z","source":"yahoo-query1"}
```

Force-test runs add `"test":true`.

## Manual test run

Actions → **spcx-price-alert** → *Run workflow* → tick **force_test** → Run. This sends a test payload whatever the price is (including a stale quote), and ignores and never writes today's marker. With the CLI: `gh workflow run spcx-price-alert.yml -f force_test=true`.

## Local tests

Requires bash, curl, jq, python3. Nothing leaves localhost.

```
bash test/run.sh                       # stub listener on 127.0.0.1, ~20 scenarios
shellcheck scripts/check.sh test/run.sh
actionlint .github/workflows/spcx-price-alert.yml
```

Try the script with no secrets and no network:

```
DRY_RUN=1 PRICE_OVERRIDE=100 MARKER_DIR=/tmp/spcx bash scripts/check.sh
```

Useful environment variables: `DRY_RUN=1`, `PRICE_OVERRIDE`, `FORCE_TEST`, `NY_TODAY` (YYYY-MM-DD, America/New_York date for freshness tests), `MARKER_DIR`, `FETCH_TIMEOUT`, and `SPCX_URL_YAHOO1` / `SPCX_URL_YAHOO2` / `SPCX_URL_STOOQ` to override the source URLs.
