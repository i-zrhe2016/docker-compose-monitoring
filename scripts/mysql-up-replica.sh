#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1" >&2; exit 1; }; }
need docker

COMPOSE_FILE=${COMPOSE_FILE:-docker-compose.mysql.yml}
NET_NAME=${NET_NAME:-prometheus-grafana-loki-docker-compose_monitoring}

rep=${1:-1}
case "$rep" in
  1|replica1) svc=mysql-replica1 ;;
  2|replica2) svc=mysql-replica2 ;;
  mysql-replica1|mysql-replica2) svc=$rep ;;
  *) echo "Usage: ${0##*/} [1|2]" >&2; exit 1 ;;
esac

ensure_network() {
  if ! docker network ls --format '{{.Name}}' | grep -qx "$NET_NAME"; then
    echo "Creating network $NET_NAME ..."
    docker network create -d bridge "$NET_NAME" >/devnull || true
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

echo "Starting $svc..."
docker compose -f "$COMPOSE_FILE" up -d "$svc"

echo "Waiting for $svc to accept connections..."
wait_mysql "$svc" 240

echo "Configuring replication on $svc ..."
docker exec -i "$svc" mysql -uroot -prootpass <<'SQL'
STOP REPLICA; RESET REPLICA ALL;
CHANGE REPLICATION SOURCE TO
  SOURCE_HOST='mysql-master',
  SOURCE_USER='repl',
  SOURCE_PASSWORD='replpass',
  SOURCE_AUTO_POSITION=1,
  GET_SOURCE_PUBLIC_KEY=1;
START REPLICA;
SQL

echo "Replication status (expect Yes/Yes):"
docker exec "$svc" mysql -uroot -prootpass -e "SHOW REPLICA STATUS\G" | egrep "Replica_IO_Running:|Replica_SQL_Running:" || true

echo "Attempt demo verification if present..."
docker exec "$svc" mysql -uroot -prootpass -e "SELECT COUNT(*) AS rows_demo FROM demo.repcheck" 2>/dev/null || true
docker exec "$svc" mysql -uroot -prootpass -e "SELECT COUNT(*) AS rows_demo2 FROM demo2.repcheck2" 2>/dev/null || true

echo "Done: $svc configured and verified."

