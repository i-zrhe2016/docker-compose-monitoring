# Prometheus、Grafana、Loki、Promtail Docker Compose 监控日志栈部署与验证

_04 Oct, 2025_

本文覆盖 Prometheus、Grafana、Loki、Promtail 组合的部署步骤与运行校验，可用于在任何具备 Docker 能力的环境快速复现监控与日志栈。

## 架构图
```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          Docker Monitoring Stack                             │
└─────────────────────────────────────────────────────────────────────────────┘

                              ┌──────────────────┐
                              │    Grafana       │
                              │   Port: 3000     │
                              │  (可视化层)       │
                              └────────┬─────────┘
                                       │
                ┌──────────────────────┼──────────────────────┐
                │                      │                      │
                │ ① Query Metrics      │ ② Query Logs         │
                │                      │                      │
        ┌───────▼───────┐      ┌──────▼───────┐     ┌────────▼────────┐
        │  Prometheus   │      │              │     │     Loki        │
        │  Port: 9090   │      │              │     │   Port: 3100    │
        │ (指标存储)     │      │              │     │  (日志聚合)      │
        └───────┬───────┘      │              │     └────────▲────────┘
                │              │              │              │
                │              │              │              │
        ┌───────┴────────┐     │              │     ┌────────┴────────┐
        │                │     │              │     │                 │
        │ ③ Scrape       │     │              │     │ ⑤ Push Logs     │
        │   Metrics      │     │              │     │   (HTTP)        │
        │   (Pull模式)    │     │              │     │                 │
        │                │     │              │     │                 │
   ┌────▼────┐    ┌─────▼─────┐              │  ┌──▼──────────┐      │
   │cAdvisor │    │nginx_     │              │  │  Promtail   │      │
   │Port:8080│    │exporter   │              │  │  Port:9080  │      │
   │         │    │Port:9113  │              │  │ (日志采集)   │      │
   └────┬────┘    └─────┬─────┘              │  └──────┬──────┘      │
        │               │                    │         │             │
        │④ 收集容器      │④ 暴露Nginx        │         │⑥ 读取日志    │
        │  指标          │  状态指标          │         │  文件        │
        │               │                    │         │             │
        │               │                    │         │             │
┌───────▼───────────────▼───────┐            │    ┌────▼─────────────┴──┐
│     Docker Runtime            │            │    │  File System         │
│  ┌──────────────────────┐     │            │    │  /var/log/           │
│  │      Nginx           │     │            │    │  /var/lib/docker/... │
│  │   Port: 8081->80     │     │            │    └──────────────────────┘
│  │   (示例应用)          │◄────┼────────────┘
│  │                      │     │
│  │  ④ stub_status       │     │
│  │     endpoint         │     │
│  └───────┬──────────────┘     │
│          │                    │
│          │⑦ 生成日志            │
│          │  (access.log,      │
│          │   error.log)       │
│          │                    │
│          ▼                    │
│    /var/log/nginx/            │
│    (挂载到宿主机)              │
└───────────────────────────────┘


═══════════════════════════════════════════════════════════════════════════════
                              数据流说明
═══════════════════════════════════════════════════════════════════════════════

① Metrics Query (查询指标)
   Grafana → Prometheus (PromQL查询)
   - 容器CPU、内存、网络使用率
   - Nginx连接数、请求数、响应时间

② Logs Query (查询日志)
   Grafana → Loki (LogQL查询)
   - Nginx访问日志
   - 容器运行日志
   - 系统日志

③ Metrics Scrape (抓取指标 - Pull模式)
   Prometheus → cAdvisor (每15s)
   - 抓取Docker容器指标
   - 抓取宿主机系统指标
   
   Prometheus → nginx_exporter (每15s)
   - 抓取Nginx性能指标

④ Metrics Export (导出指标)
   cAdvisor ← Docker Runtime (实时监控)
   nginx_exporter ← Nginx stub_status (HTTP请求)

⑤ Logs Push (推送日志 - Push模式)
   Promtail → Loki (实时流式推送)
   - 使用HTTP协议推送日志流
   - 带有标签索引(job, host, filename)

⑥ Logs Collection (收集日志)
   Promtail ← File System (tail -f 模式)
   - 监控 /var/log/ 目录
   - 监控 Docker 容器日志

⑦ Logs Generation (生成日志)
   Nginx → /var/log/nginx/
   - access.log (访问日志)
   - error.log (错误日志)
```

## 组件与端口
| 组件 | 职责 | 暴露端口 |
| --- | --- | --- |
| Prometheus | 指标采集与存储 | `9090/tcp`
| cAdvisor | Docker 容器与宿主机指标 | `8080/tcp`
| Grafana | 指标与日志可视化 | `3000/tcp`
| Loki | 日志聚合 | `3100/tcp`
| Promtail | 日志采集 Agent | `9080/tcp`（容器内）
| Nginx | 示例业务服务 | `8081->80/tcp`
| nginx_exporter | Nginx 指标暴露 | `9113/tcp`

## 目录结构
```
prometheus-grafana-loki-docker-compose/
│── docker-compose.base.yml
│── docker-compose.monitoring.yml
│── docker-compose.grafana.yml
│── docker-compose.logging.yml
│── docker-compose.app.yml
│── docker-compose.mysql.yml
│── prometheus/
│    └── prometheus.yml
│── grafana/
│    └── datasources.yml
│── promtail-config.yml
│── scripts/
│    └── nginx-metrics-assert.sh
│── nginx/
│    └── nginx.conf
│── mysql/
│    ├── master/
│    │   ├── Dockerfile
│    │   ├── master.cnf
│    │   └── init/
│    │       └── 01_init.sql
│    └── replica/
│        ├── Dockerfile
│        └── replica.cnf
│── prometheusgrafana.html
│── README.md
```
## 部署流程（逐步部署与验证）
推荐按服务逐步部署：每启动一个服务，做一次连通性验证，再继续下一步。以下均默认使用 `monitoring` 网络与 `grafana-data` 卷（自动创建）。

1) Prometheus（指标存储）
```bash
docker compose -f docker-compose.base.yml -f docker-compose.monitoring.yml up -d prometheus
curl -sSf http://localhost:9090/-/ready | grep -q "Prometheus Server is Ready." && echo OK
```

2) cAdvisor（容器与主机指标）
```bash
docker compose -f docker-compose.base.yml -f docker-compose.monitoring.yml up -d cadvisor
curl -sSf http://localhost:8080/healthz | grep -q ok && echo OK
```

3) Grafana（可视化）
```bash
docker compose -f docker-compose.base.yml -f docker-compose.grafana.yml up -d grafana
curl -sSf http://localhost:3000/api/health | grep -q '"database": "ok"' && echo OK
```
登录 `http://localhost:3000`，默认账号 `admin/admin`，首次登录请修改密码。

4) Loki（日志聚合）
```bash
docker compose -f docker-compose.base.yml -f docker-compose.logging.yml up -d loki
curl -sSf http://localhost:3100/ready | grep -q ready && echo OK
```

5) Promtail（日志采集）
```bash
docker compose -f docker-compose.base.yml -f docker-compose.logging.yml up -d promtail
docker exec grafana curl -sSf http://promtail:9080/ready | grep -q Ready && echo OK
```

6) Nginx（示例服务）
```bash
docker compose -f docker-compose.base.yml -f docker-compose.app.yml up -d nginx
curl -sSf http://localhost:8081 | grep -q "Welcome to nginx!" && echo OK
```

7) nginx_exporter（Nginx 指标）
```bash
docker compose -f docker-compose.base.yml -f docker-compose.app.yml up -d nginx_exporter
curl -sSf http://localhost:9113/metrics | grep -q '^nginx_up ' && echo OK
```

8) Prometheus 抓取验证（可选）
```bash
curl -s "http://localhost:9090/api/v1/query?query=up%7Bjob%3D%22nginx_exporter%22%7D" | grep -q '"value"' && echo OK
curl -s "http://localhost:9090/api/v1/query?query=nginx_up" | grep -q '"value"' && echo OK
```

如需一次性启动全部组件，仍可使用：
```bash
docker compose \
  -f docker-compose.base.yml \
  -f docker-compose.monitoring.yml \
  -f docker-compose.grafana.yml \
  -f docker-compose.logging.yml \
  -f docker-compose.app.yml up -d
```

### 一次性启动全部组件（可选）
如已完成逐步验证，亦可一条命令启动/重启全部服务（同上）。

### 停止与清理（可选）
```bash
docker compose \
  -f docker-compose.base.yml \
  -f docker-compose.monitoring.yml \
  -f docker-compose.grafana.yml \
  -f docker-compose.logging.yml \
  -f docker-compose.app.yml down
```
命令不会自动删除 `grafana-data` 卷，如需释放空间请手动移除。

## 验证步骤
### 一键验证 Nginx 指标（压测 + PromQL）
一键对 Nginx 进行短时压测，并基于 PromQL 校验指标是否按预期变化：
```bash
./scripts/nginx-metrics-assert.sh -c 50 -d 20s -u http://localhost:8081/
```
默认 Prometheus 地址 `http://localhost:9090`，可通过 `-s` 或环境变量 `PROM` 覆盖；
需要 `curl` 与 `jq`（或 `python3`）解析 Prometheus JSON；
断言内容包括：
- `up{job="nginx_exporter"} >= 1`
- `nginx_up == 1`
- `sum(nginx_http_requests_total)` 在压测后增加量 ≥ `MIN_DELTA`（默认 10，可通过 `-m` 或环境变量覆盖）
- 连接恒等式：`active == reading + writing + waiting`

若本机安装了 `hey` 或 `wrk` 或 `ab`，脚本会优先调用这些工具造流量；若均未安装，会用 curl 循环作为回退方案。

### 在 Grafana 中查看 Nginx 指标
1) 打开 `http://localhost:3000` 登录（默认 `admin/admin`，建议立刻修改密码）。
2) 左侧 `Explore` 选择数据源 `Prometheus`，输入以下 PromQL 直接查看：
- 每秒请求数（QPS）：`sum(rate(nginx_http_requests_total[1m]))`
- 活跃连接：`nginx_connections_active`
- 连接详情：`nginx_connections_reading`, `nginx_connections_writing`, `nginx_connections_waiting`
- 健康状态：`up{job="nginx_exporter"}`, `nginx_up`
3) 或 `Dashboards → Import` 搜索并导入社区 Nginx Exporter 仪表盘（选择数据源为 Prometheus）。

### 故障排查小贴士
- exporter 抓取失败：确认 `http://localhost:9113/metrics` 可访问，`nginx/nginx.conf` 中 `location /stub_status` 开放访问。
- Nginx 指标不增长：先用上述一键脚本造流量，或自行 `hey -z 20s -c 50 http://localhost:8081/`。

### 日志推送验证（可选）
```bash
docker compose -f docker-compose.base.yml -f docker-compose.logging.yml logs --tail 20 promtail
docker exec grafana curl -s \
  "http://loki:3100/loki/api/v1/query?query={job=\"varlogs\"}&limit=5"
```
预期日志包含 `tail routine: started`；查询结果返回带 `streams` 与 `values` 字段的 JSON。

## 日常运维建议
- **镜像更新**：执行 `docker compose ... pull` 后再 `up -d` 滚动更新。
- **数据持久化**：Grafana 使用 `grafana-data` 卷；如需持久化 Prometheus/Loki/Nginx 日志，请在 Compose 中追加卷映射。
- **安全加固**：修改 Grafana 默认密码、为外部访问配置 HTTPS 反向代理、使用防火墙限制端口暴露。

## 最近验证快照
- `docker compose ps` 显示监控、日志与示例服务组件均为 `Up`，端口映射正确。
- Prometheus `/-/ready`、cAdvisor `/healthz`、Grafana `/api/health`、Loki `/ready`、Promtail `/ready` 均返回健康状态。
- Loki `labels` API 返回 `job`、`host`、`filename` 等标签。
- Promtail 日志包含 `tail routine: started`，确认持续采集宿主与容器日志。
- 示例服务 Nginx 可通过 `http://localhost:8081` 访问，`nginx_exporter` 指标中 `nginx_up` 为 `1`。

## MySQL 一主两从部署（逐步部署与验证）
以下示例使用 MySQL 8.4，root 密码与复制账号仅用于演示，请勿用于生产。

前置条件
- 安装 Docker 与 Docker Compose v2：
```bash
docker --version && docker compose version
```
- 监控网络 `monitoring`：本仓库的脚本会在缺失时自动创建；或手动先创建：
```bash
docker compose -f docker-compose.base.yml up -d
```

步骤 0：构建镜像（部署 + 验证）
- 部署：
```bash
./scripts/mysql-build.sh
```
- 验证：
```bash
docker images | egrep "local/mysql-(master|replica):8.4"
```

步骤 1：启动主库（部署 + 验证）
- 部署：
```bash
./scripts/mysql-up-master.sh
```
- 验证：
```bash
# 1) 容器状态
docker ps --format 'table {{.Names}}\t{{.Status}}' | grep mysql-master

# 2) 基础健康检查与主库信息（版本、GTID、二进制日志）
docker exec mysql-master mysql -uroot -prootpass -e "\
SELECT VERSION() AS version; \
SHOW VARIABLES LIKE 'gtid_mode'; \
SHOW MASTER STATUS; \
SHOW DATABASES; \
USE appdb; \
SELECT * FROM items;"
```
期望：返回一条 `appdb.items` 的 `init-row` 记录，`gtid_mode=ON`，`SHOW MASTER STATUS` 有 `File`/`Position`/`Executed_Gtid_Set`。

步骤 2：启动从库1并建立复制（部署 + 验证）
- 部署：
```bash
./scripts/mysql-up-replica.sh 1
```
- 验证：
```bash
# 1) 容器状态
docker ps --format 'table {{.Names}}\t{{.Status}}' | grep mysql-replica1

# 2) 复制线程与延迟
docker exec mysql-replica1 mysql -uroot -prootpass -e "SHOW REPLICA STATUS\\G" | \
egrep "Replica_IO_Running:|Replica_SQL_Running:|Seconds_Behind_Source:|Auto_Position:"
```
期望：`Replica_IO_Running: Yes`、`Replica_SQL_Running: Yes`、`Seconds_Behind_Source` 为 0 或较小，`Auto_Position: 1`。

步骤 3：启动从库2并建立复制（部署 + 验证）
- 部署：
```bash
./scripts/mysql-up-replica.sh 2
```
- 验证：
```bash
docker exec mysql-replica2 mysql -uroot -prootpass -e "SHOW REPLICA STATUS\\G" | \
egrep "Replica_IO_Running:|Replica_SQL_Running:|Seconds_Behind_Source:|Auto_Position:"
```

步骤 4：主写从读验证（部署 + 验证）
- 部署：
```bash
./scripts/mysql-create-demo.sh
```
- 验证（可单独再次核对）：
```bash
docker exec mysql-master   mysql -uroot -prootpass -e "SELECT COUNT(*) AS m_demo  FROM demo.repcheck;  SELECT COUNT(*) AS m_demo2  FROM demo2.repcheck2;"
docker exec mysql-replica1 mysql -uroot -prootpass -e "SELECT COUNT(*) AS r1_demo FROM demo.repcheck; SELECT COUNT(*) AS r1_demo2 FROM demo2.repcheck2;"
docker exec mysql-replica2 mysql -uroot -prootpass -e "SELECT COUNT(*) AS r2_demo FROM demo.repcheck; SELECT COUNT(*) AS r2_demo2 FROM demo2.repcheck2;"
```
期望：三台返回的行数一致（例如 demo=4、demo2=6）。

常见问题与排查（含手动修复命令）
- 复制未建立或报错：查看详细错误
```bash
docker exec mysql-replica1 mysql -uroot -prootpass -e "SHOW REPLICA STATUS\\G" | egrep "Last_IO_Error:|Last_SQL_Error:|Retrieved_Gtid_Set:|Executed_Gtid_Set:"
```
- 手动重置并按 GTID 建立复制（以 replica1 为例）
```bash
docker exec -i mysql-replica1 mysql -uroot -prootpass <<'SQL'
STOP REPLICA; RESET REPLICA ALL;
CHANGE REPLICATION SOURCE TO
  SOURCE_HOST='mysql-master',
  SOURCE_USER='repl',
  SOURCE_PASSWORD='replpass',
  SOURCE_AUTO_POSITION=1,
  GET_SOURCE_PUBLIC_KEY=1;
START REPLICA;
SQL
```
- 确认 GTID 已启用（主/从均应为 ON）
```bash
docker exec mysql-master   mysql -uroot -prootpass -e "SHOW VARIABLES LIKE 'gtid_mode';"
docker exec mysql-replica1 mysql -uroot -prootpass -e "SHOW VARIABLES LIKE 'gtid_mode';"
```
- 网络与名称解析：
```bash
docker network ls | grep monitoring
docker exec mysql-replica1 getent hosts mysql-master
```

附：快速查看复制状态
```bash
./scripts/mysql-status.sh
```
