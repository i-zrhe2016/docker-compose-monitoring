#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage: ${0##*/} [-u URL] [-c CONCURRENCY] [-d DURATION] [-n REQUESTS] [-t THREADS]

Options:
  -u URL           Target URL (default: http://localhost:8081/)
  -c CONCURRENCY   Concurrent workers/clients (default: 20)
  -d DURATION      Test duration, e.g. 10s (hey/wrk only, default: 15s)
  -n REQUESTS      Total requests when fallback to ab (default: 2000)
  -t THREADS       Worker threads for wrk (default: 4)
  -h               Show this help

Environment overrides: CONCURRENCY, DURATION, REQUESTS, THREADS, URL
Tool priority: hey > wrk > ab. Requires at least one available.
USAGE
}

URL=${URL:-http://localhost:8081/}
CONCURRENCY=${CONCURRENCY:-20}
DURATION=${DURATION:-15s}
REQUESTS=${REQUESTS:-2000}
THREADS=${THREADS:-4}

while getopts ":u:c:d:n:t:h" opt; do
  case $opt in
    u) URL=$OPTARG ;;
    c) CONCURRENCY=$OPTARG ;;
    d) DURATION=$OPTARG ;;
    n) REQUESTS=$OPTARG ;;
    t) THREADS=$OPTARG ;;
    h) usage; exit 0 ;;
    :) printf 'Option -%s requires an argument\n' "$OPTARG" >&2; usage; exit 1 ;;
    *) usage; exit 1 ;;
  esac
done

need() {
  command -v "$1" >/dev/null 2>&1
}

select_tool() {
  if need hey; then
    printf 'hey'
  elif need wrk; then
    printf 'wrk'
  elif need ab; then
    printf 'ab'
  else
    return 1
  fi
}

TOOL=$(select_tool) || {
  printf 'No load-testing tool found (hey, wrk, or ab).\n' >&2
  exit 1
}

printf 'Using tool: %s\n' "$TOOL"
printf 'Target URL: %s\n' "$URL"
printf 'Concurrency: %s\n' "$CONCURRENCY"
case $TOOL in
  hey|wrk)
    printf 'Duration: %s\n' "$DURATION"
    ;;
  ab)
    printf 'Requests: %s\n' "$REQUESTS"
    ;;
 esac

printf '\nWarming up target...\n'
curl -s -o /dev/null "$URL" || printf 'Warm-up request failed (continuing).\n'

printf '\nStarting benchmark...\n'
case $TOOL in
  hey)
    hey -z "$DURATION" -c "$CONCURRENCY" "$URL"
    ;;
  wrk)
    wrk -t"$THREADS" -c"$CONCURRENCY" -d"$DURATION" "$URL"
    ;;
  ab)
    ab -n "$REQUESTS" -c "$CONCURRENCY" "$URL"
    ;;
esac
