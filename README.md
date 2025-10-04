# Prometheus和Grafana监控系统部署

_04 Oct, 2025_

## 架构图
```
                   ┌───────────────────┐
                   │     Grafana       │
                   │   (Dashboard)     │
                   │  Port: 3000       │
                   └─────────┬─────────┘
                             │
        ┌────────────────────┼────────────────────┐
        │                                         │
        ▼                                         ▼
┌───────────────────┐                     ┌───────────────────┐
│   Prometheus      │                     │       Loki        │
│ (Metrics DB)      │                     │   (Logs Store)    │
│ Port: 9090        │                     │ Port: 3100        │
└─────────┬─────────┘                     └───────────────────┘
          │
  ┌───────┼─────────┐
  │                 │
  ▼                 ▼
┌───────────┐ ┌─────────────┐
│ Node       │ │  cAdvisor   │
│ Exporter   │ │ (Containers │
│ (Host      │ │  Metrics)   │
│ Metrics)   │ │ Port: 8080  │
│ Port: 9100 │ └─────────────┘
└───────────┘
```

- node exporter 用于监控宿主机
- cadvisor 用于监控容器
- loki 用于日志存储

## 目录结构
```
docker-compose/
│── docker-compose.base.yml
│── docker-compose.monitoring.yml
│── docker-compose.grafana.yml
│── docker-compose.logging.yml
│── prometheus/
│    └── prometheus.yml
│── grafana/
│    └── datasources.yml
│── promtail-config.yml
│── prometheusgrafana.html
│── README.md
```

## 部署

### docker-compose.base.yml
参考 `docker-compose.base.yml`:
```yaml
version: '3.8'

networks:
  monitoring:
    driver: bridge    #指定网络类型为bridge

volumes:
  grafana-data:    #定义存储卷为grafana-data
```

### docker-compose.monitoring.yml
参考 `docker-compose.monitoring.yml`:
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

### prometheus.yml
参考 `prometheus/prometheus.yml`:
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

### docker-compose.grafana.yml
参考 `docker-compose.grafana.yml`:
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

### docker-compose.logging.yml
参考 `docker-compose.logging.yml`:
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

### grafana/datasources.yml
用于预配置 Grafana 数据源：
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

### promtail-config.yml
用于收集宿主机与容器日志：
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

## 使用方式
1. 启动 Prometheus 监控栈：`docker compose -f docker-compose.base.yml -f docker-compose.monitoring.yml up -d`
2. 启动 Grafana：`docker compose -f docker-compose.base.yml -f docker-compose.grafana.yml up -d`
3. 启动日志组件：`docker compose -f docker-compose.base.yml -f docker-compose.logging.yml up -d`

Grafana 默认管理员密码为 `admin`，首次登录后请及时修改。
