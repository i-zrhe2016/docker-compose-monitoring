#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1" >&2; exit 1; }; }
need docker

show_status() {
  local name=$1
  echo "\n==> $name"
  if ! docker ps --format '{{.Names}}' | grep -qx "$name"; then
    echo "$name not running"; return
  fi
  docker exec "$name" mysql -uroot -prootpass -e "SHOW REPLICA STATUS\G" | egrep "Replica_IO_Running:|Replica_SQL_Running:|Seconds_Behind_Source:|Auto_Position:|Retrieved_Gtid_Set:|Executed_Gtid_Set:" || true
}

show_status mysql-replica1
show_status mysql-replica2

echo "\nIf replication is healthy, IO/SQL should be Yes/Yes and Seconds_Behind_Source small."

