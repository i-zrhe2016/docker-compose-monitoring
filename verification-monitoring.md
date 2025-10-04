# 监控与日志栈部署与测试指南

本文档给出 Prometheus、Grafana、Loki、Promtail 组合的完整部署与校验流程，并内嵌所有相关配置，便于在其他环境中快速复现。

## 1. 环境说明
- 测试时间：2025-10-04（UTC）
- Docker 运行于本地主机，已安装 Docker Engine 与 Compose V2
- 当前目录包含所有 Compose 与配置文件，文档中路径均以该目录为相对路径

### 1.1 组件与端口一览
| 组件 | 描述 | 暴露端口 |
| --- | --- | --- |
| Prometheus | 指标采集与存储 | `9090/tcp`
| cAdvisor | Docker 容器与宿主机指标 | `8080/tcp`
| Node Exporter | 宿主机指标 | `9100/tcp`
| Grafana | 指标与日志可视化 | `3000/tcp`
| Loki | 日志聚合 | `3100/tcp`
| Promtail | 日志采集 Agent | `9080/tcp` (容器内部 HTTP)

## 2. 配置清单
以下配置无需额外修改即可使用，若需自定义请在部署前调整。

### 2.1 `docker-compose.base.yml`
```yaml
version: '3.8'

networks:
  monitoring:
    driver: bridge    #指定网络类型为bridge

volumes:
  grafana-data:    #定义存储卷为grafana-data
```

### 2.2 `docker-compose.monitoring.yml`
```yaml
version: '3.8'

services:
  prometheus:
    image: prom/prometheus:latest
    container_name: prometheus
    ports:
      - "9090:9090"
    volumes:
      - ./prometheus:/etc/prometheus    #挂载./prometheus目录到容器内
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
    networks:
      - monitoring    #prometheus放入网络中

  cadvisor:
    image: gcr.io/cadvisor/cadvisor:latest
    container_name: cadvisor
    ports:
      - "8080:8080"
    volumes:
      - /:/rootfs:ro
      - /var/run:/var/run:rw
      - /sys:/sys:ro
      - /var/lib/docker/:/var/lib/docker:ro
      - /cgroup:/cgroup:ro
    networks:
      - monitoring    #cadvisor放入网络中

  node_exporter:
    image: prom/node-exporter:latest
    container_name: node_exporter
    ports:
      - "9100:9100"
    networks:
      - monitoring    #node_exporter放入网络中
```

### 2.3 `docker-compose.grafana.yml`
```yaml
version: '3.8'

services:
  grafana:
    image: grafana/grafana:latest
    container_name: grafana
    ports:
      - "3000:3000"
    volumes:
      - ./grafana:/etc/grafana/provisioning/datasources
      - grafana-data:/var/lib/grafana
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=admin
    networks:
      - monitoring
```

### 2.4 `docker-compose.logging.yml`
```yaml
version: '3.8'

services:
  loki:
    image: grafana/loki:latest
    container_name: loki
    ports:
      - "3100:3100"
    command: -config.file=/etc/loki/local-config.yaml
    networks:
      - monitoring

  promtail:
    image: grafana/promtail:latest
    container_name: promtail
    volumes:
      - /var/log:/var/log
      - /var/lib/docker/containers:/var/lib/docker/containers
      - ./promtail-config.yml:/etc/promtail/promtail-config.yml
    command: -config.file=/etc/promtail/promtail-config.yml
    networks:
      - monitoring
```

### 2.5 `prometheus/prometheus.yml`
```yaml
global:
  scrape_interval: 5s

scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['prometheus:9090']

  - job_name: 'node_exporter'
    static_configs:
      - targets: ['node_exporter:9100']

  - job_name: 'cadvisor'
    static_configs:
      - targets: ['cadvisor:8080']
```

### 2.6 `grafana/datasources.yml`
```yaml
apiVersion: 1

datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
  - name: Loki
    type: loki
    access: proxy
    url: http://loki:3100
```

### 2.7 `promtail-config.yml`
```yaml
server:
  http_listen_port: 9080
  grpc_listen_port: 0

positions:
  filename: /tmp/positions.yaml

clients:
  - url: http://loki:3100/loki/api/v1/push

scrape_configs:
  - job_name: system-logs
    static_configs:
      - targets:
          - localhost
        labels:
          job: varlogs
          host: ${HOSTNAME}
          __path__: /var/log/*log
  - job_name: docker-containers
    static_configs:
      - targets:
          - localhost
        labels:
          job: containers
          host: ${HOSTNAME}
          __path__: /var/lib/docker/containers/*/*.log
```

## 3. 部署流程
### 3.1 启动监控组件
```bash
docker compose \
  -f docker-compose.base.yml \
  -f docker-compose.monitoring.yml up -d
```
成功后 `prometheus`、`cadvisor`、`node_exporter` 会加入 `monitoring` 网络，并在宿主机暴露端口 9090/8080/9100。

### 3.2 启动 Grafana
```bash
docker compose \
  -f docker-compose.base.yml \
  -f docker-compose.grafana.yml up -d
```
Grafana 默认账号 `admin` / `admin`，首次登录后请修改密码。

### 3.3 启动日志组件
```bash
docker compose \
  -f docker-compose.base.yml \
  -f docker-compose.logging.yml up -d
```
Loki 会监听 `3100`，Promtail 通过配置自动推送系统与容器日志到 Loki。

> **一次性启动全部组件**：
> ```bash
> docker compose \
>   -f docker-compose.base.yml \
>   -f docker-compose.monitoring.yml \
>   -f docker-compose.grafana.yml \
>   -f docker-compose.logging.yml up -d
> ```

### 3.4 关闭与清理（可选）
```bash
docker compose \
  -f docker-compose.base.yml \
  -f docker-compose.monitoring.yml \
  -f docker-compose.grafana.yml \
  -f docker-compose.logging.yml down
```
默认会保留 `grafana-data` 卷，可根据需要手动删除。

## 4. 测试步骤与预期
以下命令均在项目根目录执行。

### 4.1 Compose 容器状态
```bash
docker compose -f docker-compose.base.yml -f docker-compose.monitoring.yml -f docker-compose.grafana.yml -f docker-compose.logging.yml ps
```
预期所有服务状态为 `Up`，并带有正确端口映射。

### 4.2 Prometheus 与 Node Exporter
```bash
curl -sSf http://localhost:9090/-/ready
curl -sSf http://localhost:9100/metrics | head -n 5
```
- Ready 接口返回 `Prometheus Server is Ready.`
- `9100/metrics` 输出以 `# HELP` 开头的指标。

### 4.3 cAdvisor
```bash
curl -sSf http://localhost:8080/healthz
```
返回 `ok` 表示容器健康。

### 4.4 Grafana
```bash
curl -s http://localhost:3000/login | head -n 5
curl -sSf http://localhost:3000/api/health
```
- 登录页应返回 HTML 头部。
- 健康接口预期 JSON：
```json
{
  "database": "ok",
  "version": "12.2.0",
  "commit": "..."
}
```

### 4.5 Loki
```bash
# Loki 初启可能短暂返回 503，等待数秒后再次请求
curl -sSf http://localhost:3100/ready
curl -s "http://localhost:3100/loki/api/v1/labels"
```
- `/ready` 返回 `ready`
- `/loki/api/v1/labels` 返回 `status: success` 及可用标签列表。

### 4.6 Promtail
Promtail HTTP 端口未映射到宿主机，需要通过同一网络的容器访问：
```bash
docker exec grafana curl -sSf http://promtail:9080/ready
```
返回 `Ready` 表示 Promtail 正常。

### 4.7 日志推送验证（可选）
1. 查看 Promtail 最近日志，确认已开始跟踪宿主日志：
   ```bash
   docker compose -f docker-compose.base.yml -f docker-compose.logging.yml logs --tail 20 promtail
   ```
2. 使用 Loki API 查询最新日志（示例按标签 `job=varlogs`）：
   ```bash
   docker exec grafana curl -s \
     "http://loki:3100/loki/api/v1/query?query={job=\"varlogs\"}&limit=5"
   ```
   预期收到包含 `streams` 与 `values` 字段的 JSON。

## 5. 日常运维建议
- **监控栈更新**：更新镜像后执行 `docker compose ... pull` 与 `up -d`.
- **数据持久化**：Grafana 使用 `grafana-data` 卷保存仪表盘；Prometheus/Loki 如需持久化可在 Compose 中追加映射。
- **安全性**：
  - 修改 Grafana 默认密码，配置 HTTPS 反向代理。
  - 使用防火墙限制对外暴露的端口。

## 6. 已验证结果快照
近期一次验证的核心结果：
- `docker compose ps` 显示所有组件 `Up` 并成功映射端口。
- Prometheus `/-/ready`、cAdvisor `/healthz`、Grafana `/api/health`、Loki `/ready`、Promtail `/ready` 均返回健康状态。
- Loki 标签 API 返回 `"job", "host", "filename"` 等标签。
- Promtail 日志出现多条 `tail routine: started`，确认日志持续采集。

按照以上步骤可在任意具备 Docker 能力的环境中部署并验证完整的监控与日志链路。
