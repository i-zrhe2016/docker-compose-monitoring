#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1" >&2; exit 1; }; }
need docker

COMPOSE_FILE=${COMPOSE_FILE:-docker-compose.mysql.yml}
NET_NAME=${NET_NAME:-prometheus-grafana-loki-docker-compose_monitoring}

ensure_network() {
  if ! docker network ls --format '{{.Name}}' | grep -qx "$NET_NAME"; then
    echo "Creating network $NET_NAME ..."
    docker network create -d bridge "$NET_NAME" >/dev/null || true
  fi
}

wait_mysql() {
  local name=$1 tries=${2:-240}
  for i in $(seq 1 "$tries"); do
    if docker exec "$name" mysql -uroot -prootpass -e 'SELECT 1' >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

ensure_network

echo "Starting mysql-master..."
docker compose -f "$COMPOSE_FILE" up -d mysql-master

echo "Waiting for mysql-master to accept connections..."
if ! wait_mysql mysql-master 240; then
  echo "mysql-master did not become ready in time" >&2
  docker logs --tail 120 mysql-master || true
  exit 1
fi

echo "Master ready. Running sanity queries..."
docker exec mysql-master mysql -uroot -prootpass -e "SELECT VERSION() AS version; SHOW DATABASES; SHOW MASTER STATUS; USE appdb; SELECT * FROM items;" || true

echo "Done: master is up and initialized."
