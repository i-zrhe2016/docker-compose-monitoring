# Prometheus + Grafana 最小部署与验证

只保留与 Prometheus、Grafana 指标监控相关的代码与文档，便于在本地或服务器上快速部署并完成最小化验证。

## 目录结构
```
prometheus-grafana-loki-docker-compose/
│── docker-compose.base.yml           # 网络与卷
│── docker-compose.monitoring.yml     # Prometheus + cAdvisor（容器指标）
│── docker-compose.grafana.yml        # Grafana（自动配置数据源）
│── prometheus/
│   └── prometheus.yml                # Prometheus 抓取配置（自监控 + cAdvisor）
│── grafana/
│   └── datasources.yml               # 预配置 Prometheus 数据源
│── README.md
```

## 快速开始
逐步启动并在每步做一次健康检查。

1) 基础网络/卷
```
docker compose -f docker-compose.base.yml up -d
```

2) Prometheus（含 cAdvisor 指标）
```
docker compose -f docker-compose.base.yml -f docker-compose.monitoring.yml up -d
curl -sSf http://localhost:9090/-/ready | grep -q "Prometheus Server is Ready." && echo OK
curl -sSf http://localhost:8080/healthz | grep -q ok && echo OK   # cAdvisor
```

3) Grafana（自动接入 Prometheus）
```
docker compose -f docker-compose.base.yml -f docker-compose.grafana.yml up -d
curl -sSf http://localhost:3000/api/health | grep -q '"database": "ok"' && echo OK
```
打开浏览器访问 `http://localhost:3000`，默认账号密码 `admin/admin`（首次登录请修改）。

（如需日志采集，可单独引入日志系统。）

一次性启动全部组件：
```
docker compose \
  -f docker-compose.base.yml \
  -f docker-compose.monitoring.yml \
  -f docker-compose.grafana.yml \
  up -d
```

停止与清理：
```
docker compose \
  -f docker-compose.base.yml \
  -f docker-compose.monitoring.yml \
  -f docker-compose.grafana.yml \
  down
```

## 验证要点
- Prometheus 就绪：`curl -sSf http://localhost:9090/-/ready`
- Grafana 健康：`curl -sSf http://localhost:3000/api/health`
- 当前未包含日志栈。
- Prometheus 基础查询：
  - 自身抓取：`curl -s "http://localhost:9090/api/v1/query?query=up{job=\"prometheus\"}"`
  - 容器指标（cAdvisor）：`curl -s "http://localhost:9090/api/v1/targets" | jq '.data.activeTargets[] | select(.labels.job=="cadvisor")'`（如未安装 jq，可忽略）
在 Grafana 中：左侧 Explore 选择数据源 `Prometheus`，即可交互式查询（PromQL）。

## 说明
- 已删除与监控栈无关的示例应用（Nginx/exporter）与 MySQL 相关代码、脚本与文档。
- `prometheus/prometheus.yml` 仅保留 Prometheus 自监控与 `cAdvisor` 抓取目标。
- 如需增加业务 Exporter 或目标，请在 `prometheus/prometheus.yml` 追加对应 `job`。

## 常见问题
- 端口占用：确保 `9090`（Prometheus）、`3000`（Grafana）、`8080`（cAdvisor）未被占用。
