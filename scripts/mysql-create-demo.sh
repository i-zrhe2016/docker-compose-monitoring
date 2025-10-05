#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1" >&2; exit 1; }; }
need docker

echo "Creating demo databases/tables on master and inserting sample rows..."
docker exec mysql-master mysql -uroot -prootpass -e "\
CREATE DATABASE IF NOT EXISTS demo; \
CREATE TABLE IF NOT EXISTS demo.repcheck (id BIGINT PRIMARY KEY AUTO_INCREMENT, note VARCHAR(64), ts TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP); \
INSERT INTO demo.repcheck(note) VALUES ('row1'),('row2'); \
CREATE DATABASE IF NOT EXISTS demo2; \
CREATE TABLE IF NOT EXISTS demo2.repcheck2 (id BIGINT PRIMARY KEY AUTO_INCREMENT, note VARCHAR(64), ts TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP); \
INSERT INTO demo2.repcheck2(note) VALUES ('r1'),('r2'),('r3');"

sleep 2

echo "Row counts (master):"
docker exec mysql-master mysql -uroot -prootpass -e "SELECT COUNT(*) AS m_demo FROM demo.repcheck; SELECT COUNT(*) AS m_demo2 FROM demo2.repcheck2;"

echo "Row counts (replica1):"
docker exec mysql-replica1 mysql -uroot -prootpass -e "SELECT COUNT(*) AS r1_demo FROM demo.repcheck; SELECT COUNT(*) AS r1_demo2 FROM demo2.repcheck2;"

echo "Row counts (replica2):"
docker exec mysql-replica2 mysql -uroot -prootpass -e "SELECT COUNT(*) AS r2_demo FROM demo.repcheck; SELECT COUNT(*) AS r2_demo2 FROM demo2.repcheck2;"

echo "Done: demo data created and verified."

