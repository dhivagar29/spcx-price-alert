# Test output

Run on 2026-11-15T06:46:22Z, Linux, GNU bash, version 5.2.37(1)-release, jq jq-1.7, shellcheck 0.10.0, actionlint 1.7.7.

## `bash test/run.sh`

All scenarios run against a stub listener on 127.0.0.1. The real webhook is never contacted.

```
== 1. below threshold -> one POST with correct body/header, marker written
ok   - exit 0
ok   - exactly 1 POST
ok   - POST path is webhook
ok   - Authorization: Bearer <key>
ok   - Content-Type json
ok   - body fields
ok   - no test key in body
ok   - price is a JSON number
ok   - marker written
ok   - no secrets in output
== 1b. price exactly at threshold -> POST
ok   - exit 0 and 1 POST
== 1c. secrets with trailing CR/LF are stripped
ok   - exit 0, header clean
== 2. above threshold -> no POST, no marker
ok   - exit 0
ok   - 0 POSTs
ok   - no marker dir created
ok   - says above threshold
== 3. FORCE_TEST=true with high price -> POST with test:true, no marker
ok   - exit 0
ok   - exactly 1 POST
ok   - body test:true
ok   - no marker dir created
== 3b. FORCE_TEST=1 bypasses an existing marker and leaves it untouched
ok   - exit 0 and 1 POST
ok   - marker unchanged
== 3c. FORCE_TEST with failing webhook -> non-zero, no marker
ok   - non-zero exit
ok   - no marker dir created
== 4. marker present, no force -> exit 0, no fetch, no POST
ok   - exit 0
ok   - no requests at all
ok   - says already fired
== 5. missing secrets (not DRY_RUN) -> non-zero, no values printed
ok   - non-zero exit
ok   - names both secrets
ok   - 0 POSTs
ok   - empty key -> non-zero
ok   - URL not printed
ok   - missing URL -> non-zero, key not printed
== 6. all sources fail -> non-zero, no POST
ok   - non-zero exit
ok   - 0 POSTs
ok   - logs each source failure
ok   - no marker
ok   - stooq N/D -> non-zero, 0 POSTs
== 7. fallback chain picks the source that produced the price
ok   - yahoo-query2 used, POST sent
ok   - as_of_utc from regularMarketTime
ok   - price from meta
ok   - yahoo-query1 used
ok   - stooq used, price 103.5
== 8. webhook failure (non-test) -> non-zero, no marker, URL redacted
ok   - non-zero exit
ok   - no marker
ok   - URL/key not printed
ok   - connect error -> non-zero, no marker
ok   - connect error output redacted
== 9. DRY_RUN=1 without secrets prints payload, no POST
ok   - exit 0, payload printed, 0 POSTs
passed: 49  failed: 0
exit=0
```

## `shellcheck scripts/check.sh test/run.sh`

```
(no findings) exit=0
```

## `actionlint .github/workflows/spcx-price-alert.yml`

```
(no findings) exit=0
```

## Live fetch check (DRY_RUN=1, no secrets, no POST)

After switching the script to a Windows Chrome User-Agent (Yahoo returned 429 for a generic Linux UA from this box):

```
SPCX price 139.11 (as of 2026-11-13T21:00:01Z, source yahoo-query1); threshold 115.00
Price is above threshold; no alert.
rc=0
```

`query1.finance.yahoo.com` and `query2.finance.yahoo.com` both resolved SPCX at 139.11 USD, `regularMarketTime` 1794603601 = 2026-11-13T21:00:01Z (Friday cash close; this check ran on Sunday 2026-11-15). Stooq CSV `https://stooq.com/q/l/?s=spcx.us&f=sd2t2ohlcv&h&e=csv` returned HTTP 404 from this box. No POST was sent (DRY_RUN, and the price is above 115.00).
