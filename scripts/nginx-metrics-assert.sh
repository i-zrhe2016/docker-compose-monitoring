#!/usr/bin/env bash
set -euo pipefail

# Nginx auto load-test + PromQL assertions
#
# Requirements:
# - curl
# - jq or python3 (for parsing Prometheus JSON)
# - One of: hey / wrk / ab (optional; falls back to curl)
#
# Defaults can be overridden via env or flags.
#   PROM=http://localhost:9090
#   URL=http://localhost:8081/
#   CONCURRENCY=30
#   DURATION=20s
#   MIN_DELTA=10

PROM=${PROM:-http://localhost:9090}
URL=${URL:-http://localhost:8081/}
CONCURRENCY=${CONCURRENCY:-30}
DURATION=${DURATION:-20s}
MIN_DELTA=${MIN_DELTA:-10}

usage() {
  cat <<USAGE
Usage: ${0##*/} [-s PROM] [-u URL] [-c CONCURRENCY] [-d DURATION] [-m MIN_DELTA]

Options:
  -s PROM          Prometheus base URL (default: $PROM)
  -u URL           Target URL to load (default: $URL)
  -c CONCURRENCY   Load concurrency (default: $CONCURRENCY)
  -d DURATION      Load duration (hey/wrk) like 20s (default: $DURATION)
  -m MIN_DELTA     Min expected increase of requests (default: $MIN_DELTA)
  -h               Show help

Env overrides: PROM, URL, CONCURRENCY, DURATION, MIN_DELTA
USAGE
}

while getopts ":s:u:c:d:m:h" opt; do
  case $opt in
    s) PROM=$OPTARG ;;
    u) URL=$OPTARG ;;
    c) CONCURRENCY=$OPTARG ;;
    d) DURATION=$OPTARG ;;
    m) MIN_DELTA=$OPTARG ;;
    h) usage; exit 0 ;;
    :) printf 'Option -%s requires an argument\n' "$OPTARG" >&2; usage; exit 1 ;;
    *) usage; exit 1 ;;
  esac
done

need() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'Missing required command: %s\n' "$1" >&2
    exit 1
  }
}

need curl

have_jq=false
have_py=false
if command -v jq >/dev/null 2>&1; then
  have_jq=true
elif command -v python3 >/dev/null 2>&1; then
  have_py=true
else
  printf 'Need jq or python3 to parse Prometheus JSON. Please install one.\n' >&2
  exit 1
fi

info() { printf '\n==> %s\n' "$1"; }
ok()   { printf 'OK: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

prom_query() {
  local q=$1
  curl -sS --get "$PROM/api/v1/query" --data-urlencode "query=$q"
}

prom_scalar() {
  # Prints the first series value as a scalar string
  local q=$1 resp
  resp=$(prom_query "$q")
  if $have_jq; then
    # Ensure we have at least one result and status success
    echo "$resp" | jq -e -r 'select(.status=="success") | select(.data.result | length > 0) | .data.result[0].value[1]'
  else
    # python3 fallback
    python3 - "$resp" <<'PY'
import sys, json
data = json.loads(sys.argv[1] if len(sys.argv)>1 else sys.stdin.read())
if data.get('status') != 'success' or not data.get('data') or not data['data'].get('result'):
    print('')
    sys.exit(2)
try:
    print(data['data']['result'][0]['value'][1])
except Exception as e:
    print('')
    sys.exit(3)
PY
  fi
}

fge() {
  # float greater or equal: $1 >= $2 ?
  awk -v a="$1" -v b="$2" 'BEGIN{exit !((a+0) >= (b+0))}'
}

fle() {
  # float less or equal: $1 <= $2 ?
  awk -v a="$1" -v b="$2" 'BEGIN{exit !((a+0) <= (b+0))}'
}

dash_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)


info "Checking Prometheus readiness at $PROM/-/ready"
curl -fsS "$PROM/-/ready" | grep -q "Prometheus Server is Ready." || fail "Prometheus not ready"
ok "Prometheus is ready"

info "Asserting exporter targets are up"
val=$(prom_scalar 'up{job="nginx_exporter"}') || true
[ -n "${val:-}" ] && fge "$val" 1 || fail "up{job=\"nginx_exporter\"} < 1 (got: ${val:-empty})"
ok "up{job=\"nginx_exporter\"} >= 1 (got: $val)"

val=$(prom_scalar 'nginx_up') || true
[ -n "${val:-}" ] && fge "$val" 1 || fail "nginx_up != 1 (got: ${val:-empty})"
ok "nginx_up == 1 (got: $val)"

info "Reading baseline total requests"
before=$(prom_scalar 'sum(nginx_http_requests_total)') || true
[ -n "${before:-}" ] || fail "Could not read baseline nginx_http_requests_total"
printf 'Baseline requests: %s\n' "$before"

info "Running load: conc=$CONCURRENCY duration=$DURATION url=$URL"
# Prefer hey > wrk > ab; else curl fallback
if command -v hey >/dev/null 2>&1; then
  printf 'Using tool: hey\n'
  hey -z "$DURATION" -c "$CONCURRENCY" "$URL" || true
elif command -v wrk >/dev/null 2>&1; then
  printf 'Using tool: wrk\n'
  wrk -t4 -c"$CONCURRENCY" -d"$DURATION" "$URL" || true
elif command -v ab >/dev/null 2>&1; then
  printf 'Using tool: ab\n'
  # Approximate requests for ab (duration-independent):
  REQS=$(( CONCURRENCY * 200 ))
  ab -n "$REQS" -c "$CONCURRENCY" "$URL" || true
else
  info "No hey/wrk/ab found; using curl fallback load"
  duration_secs=$(printf '%s' "$DURATION" | sed -E 's/[[:space:]]//g; s/s$//I')
  [[ "$duration_secs" =~ ^[0-9]+$ ]] || duration_secs=15
  end_ts=$(( $(date +%s) + duration_secs ))
  while (( $(date +%s) < end_ts )); do
    for ((i=0; i<CONCURRENCY; i++)); do
      curl -s -o /dev/null "$URL" &
    done
    wait || true
  done
fi

# Allow Prometheus a couple of scrapes to ingest new samples
sleep 6

info "Reading post-load total requests"
after=$(prom_scalar 'sum(nginx_http_requests_total)') || true
[ -n "${after:-}" ] || fail "Could not read post-load nginx_http_requests_total"
printf 'Post-load requests: %s\n' "$after"

delta=$(awk -v a="$after" -v b="$before" 'BEGIN{printf "%.0f", (a+0) - (b+0)}')
printf 'Delta requests: %s\n' "$delta"
fge "$delta" "$MIN_DELTA" || fail "Requests increase ($delta) < MIN_DELTA ($MIN_DELTA)"
ok "Requests increased by $delta (>= $MIN_DELTA)"

info "Asserting connections identity: active == reading+writing+waiting"
diff_val=$(prom_scalar 'abs(nginx_connections_active - (nginx_connections_reading + nginx_connections_writing + nginx_connections_waiting))') || true
[ -n "${diff_val:-}" ] || fail "Could not compute connections identity"
fle "$diff_val" 1 || fail "Active vs (R+W+W) mismatch: $diff_val (> 1)"
ok "Connections identity holds (abs diff=$diff_val)"

info "Sampling recent QPS (sum(rate(nginx_http_requests_total[30s])))"
qps=$(prom_scalar 'sum(rate(nginx_http_requests_total[30s]))') || true
[ -n "${qps:-}" ] && printf 'Recent QPS (approx): %s\n' "$qps" || printf 'Recent QPS: (unavailable)\n'

printf '\nAll Nginx PromQL assertions passed.\n'
