#!/usr/bin/env bash
set -euo pipefail

need() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'Missing required command: %s\n' "$1" >&2
    exit 1
  }
}

need curl

info() { printf '\n==> %s\n' "$1"; }

check_http() {
  local name=$1 url=$2 needle=$3 attempts=${4:-5} pause=${5:-3}
  info "Checking ${name} (${url})"
  local attempt output status body code
  for ((attempt=1; attempt<=attempts; attempt++)); do
    status=0
    output=$(curl -sS -w '\n%{http_code}' "$url" 2>&1) || status=$?
    if (( status == 0 )); then
      body=${output%$'\n'*}
      code=${output##*$'\n'}
      if [[ $code == 200 && $body == *"$needle"* ]]; then
        printf 'OK: %s\n' "$name"
        return 0
      fi
      printf 'Attempt %d/%d failed (code=%s)\n' "$attempt" "$attempts" "$code"
    else
      printf 'Attempt %d/%d error: %s\n' "$attempt" "$attempts" "$output"
    fi
    sleep "$pause"
  done
  printf 'FAILED: %s (%s)\n' "$name" "$url" >&2
  printf 'Last response:\n%s\n' "$output" >&2
  exit 1
}

parse_metric() {
  printf '%s' "$1" | awk -v key="$2" '$1 == key {print $2; exit}'
}

show_nginx_metrics() {
  info "Fetching nginx exporter metrics"
  local metrics
  metrics=$(curl -sSf http://localhost:9113/metrics)
  local active reading writing waiting upstreams requests
  active=$(parse_metric "$metrics" nginx_connections_active)
  reading=$(parse_metric "$metrics" nginx_connections_reading)
  writing=$(parse_metric "$metrics" nginx_connections_writing)
  waiting=$(parse_metric "$metrics" nginx_connections_waiting)
  requests=$(parse_metric "$metrics" nginx_http_requests_total)
  upstreams=$(printf '%s' "$metrics" | awk '/^nginx_upstream_requests_total/ {sum+=$2} END {print sum+0}')
  printf 'Nginx connections active : %s\n' "${active:--}"
  printf 'Nginx connections reading: %s\n' "${reading:--}"
  printf 'Nginx connections writing: %s\n' "${writing:--}"
  printf 'Nginx connections waiting: %s\n' "${waiting:--}"
  printf 'Nginx total requests     : %s\n' "${requests:--}"
  printf 'Nginx upstream req total : %s\n' "${upstreams:--}"
}

check_http "Prometheus readiness" "http://localhost:9090/-/ready" "Prometheus Server is Ready."
check_http "cAdvisor health" "http://localhost:8080/healthz" "ok" 3 2
check_http "Grafana login" "http://localhost:3000/login" "<!DOCTYPE html>" 3 2
check_http "Grafana API health" "http://localhost:3000/api/health" '"database": "ok"' 3 2
check_http "Loki readiness" "http://localhost:3100/ready" "ready" 10 3
check_http "Loki labels" "http://localhost:3100/loki/api/v1/labels" '"status":"success"' 5 3
check_http "Nginx welcome" "http://localhost:8081" "Welcome to nginx!" 3 2
check_http "nginx_exporter metrics" "http://localhost:9113/metrics" "nginx_up" 3 2

show_nginx_metrics

info "All checks passed"
