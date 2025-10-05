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
│── prometheus/
│    └── prometheus.yml
│── grafana/
│    └── datasources.yml
│── promtail-config.yml
│── scripts/
│    └── nginx-metrics-assert.sh
│── nginx/
│    └── nginx.conf
│── prometheusgrafana.html
│── README.md
```
## 部署流程
以下命令可单独或一次性启动所有组件，默认使用 `monitoring` 网络与 `grafana-data` 卷。

### 启动监控组件
```bash
docker compose \
  -f docker-compose.base.yml \
  -f docker-compose.monitoring.yml up -d
```

### 启动 Grafana
```bash
docker compose \
  -f docker-compose.base.yml \
  -f docker-compose.grafana.yml up -d
```
Grafana 默认账号 `admin` / `admin`，首次登录后请修改密码。

### 启动日志组件
```bash
docker compose \
  -f docker-compose.base.yml \
  -f docker-compose.logging.yml up -d
```
Promtail 通过配置文件自动采集宿主机与容器日志并推送到 Loki。

### 启动示例服务（Nginx）
```bash
docker compose \
  -f docker-compose.base.yml \
  -f docker-compose.app.yml up -d
```
示例服务默认监听 `http://localhost:8081`，Nginx exporter 暴露指标 `http://localhost:9113/metrics`。

### 一次性启动全部组件
```bash
docker compose \
  -f docker-compose.base.yml \
  -f docker-compose.monitoring.yml \
  -f docker-compose.grafana.yml \
  -f docker-compose.logging.yml \
  -f docker-compose.app.yml up -d
```

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
确保容器在本目录下启动。

### Compose 服务状态
```bash
docker compose \
  -f docker-compose.base.yml \
  -f docker-compose.monitoring.yml \
  -f docker-compose.grafana.yml \
  -f docker-compose.logging.yml ps
```
预期所有服务状态为 `Up`，端口映射符合组件表。

### Prometheus
```bash
curl -sSf http://localhost:9090/-/ready
```
`/ready` 返回 `Prometheus Server is Ready.`

### cAdvisor
```bash
curl -sSf http://localhost:8080/healthz
```
返回 `ok` 即表示健康。

### Grafana
```bash
curl -s http://localhost:3000/login | head -n 5
curl -sSf http://localhost:3000/api/health
```
- 登录页返回 HTML 头部。
- `/api/health` 返回 `{"database":"ok",...}` JSON。

### Loki
```bash
curl -sSf http://localhost:3100/ready
curl -s "http://localhost:3100/loki/api/v1/labels"
```
- `/ready` 返回 `ready`
- `labels` 接口状态为 `success`

### 示例服务（Nginx）
```bash
curl -sSf http://localhost:8081 | head -n 5
```
默认首页返回 Nginx 欢迎页面片段。

### Nginx Exporter
```bash
curl -sSf http://localhost:9113/metrics | head -n 5
```
预期包含 `# HELP nginx_up` 等指标行。

### 单容器快速验证（无本机依赖）
在 Linux 上可用一个临时容器跑完所有连通性检查，无需本机安装 curl：

方式 A：host 网络（直接访问本机映射端口）
```bash
docker run --rm --network host curlimages/curl:8.9.1 sh -s <<'SH'
set -eu
check() {
  name=$1 url=$2 needle=$3
  printf "\n==> %s (%s)\n" "$name" "$url"
  out=$(curl -sS -w "\n%{http_code}" "$url") || { echo "curl error"; exit 1; }
  body=${out%$'\n'*}
  code=${out##*$'\n'}
  if [ "$code" = 200 ] && printf '%s' "$body" | grep -q "$needle"; then
    echo "OK: $name"
  else
    echo "FAIL: $name (code=$code)"; printf '%s\n' "$body" | head -n 20; exit 1
  fi
}
check "Prometheus readiness" "http://localhost:9090/-/ready" "Prometheus Server is Ready."
check "Grafana API health" "http://localhost:3000/api/health" '"database": "ok"'
check "Loki readiness" "http://localhost:3100/ready" "ready"
check "Nginx welcome" "http://localhost:8081" "Welcome to nginx!"
check "nginx_exporter metrics" "http://localhost:9113/metrics" "nginx_up"
echo "\nAll checks passed."
SH
```

方式 B：加入 Compose 网络（容器名直连，适用于非 Linux 环境）
```bash
# 如网络名不同，请以 `docker network ls | grep _monitoring` 为准
NET=prometheus-grafana-loki-docker-compose_monitoring
docker run --rm --network "$NET" curlimages/curl:8.9.1 sh -s <<'SH'
set -eu
check() {
  name=$1 url=$2 needle=$3
  printf "\n==> %s (%s)\n" "$name" "$url"
  out=$(curl -sS -w "\n%{http_code}" "$url") || { echo "curl error"; exit 1; }
  body=${out%$'\n'*}
  code=${out##*$'\n'}
  if [ "$code" = 200 ] && printf '%s' "$body" | grep -q "$needle"; then
    echo "OK: $name"
  else
    echo "FAIL: $name (code=$code)"; printf '%s\n' "$body" | head -n 20; exit 1
  fi
}
check "Prometheus readiness" "http://prometheus:9090/-/ready" "Prometheus Server is Ready."
check "Grafana API health" "http://grafana:3000/api/health" '"database": "ok"'
check "Loki readiness" "http://loki:3100/ready" "ready"
check "Nginx welcome" "http://nginx" "Welcome to nginx!"
check "nginx_exporter metrics" "http://nginx_exporter:9113/metrics" "nginx_up"
echo "\nAll checks passed."
SH
```

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

### Promtail
Promtail 端口未映射到宿主机，可借助 Grafana 容器验证：
```bash
docker exec grafana curl -sSf http://promtail:9080/ready
```
返回 `Ready` 表示采集 Agent 正常。

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
