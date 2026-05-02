# 企业级项目03: Prometheus + Grafana 全栈监控告警系统

## 📋 项目概述

完整的企业级监控告警方案，覆盖主机、容器、应用、数据库、中间件全链路监控。

**技术栈**: Prometheus + Grafana + AlertManager + Node Exporter + cAdvisor + Loki + Blackbox Exporter

---

## 🏗️ 架构图

```
┌─────────────────────────────────────────────────────────────────┐
│                    监控告警系统架构                                │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  采集层:                                                         │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐           │
│  │  Node    │ │ cAdvisor │ │ Blackbox │ │  MySQL   │           │
│  │ Exporter │ │(容器监控) │ │(探针监控) │ │ Exporter │           │
│  │  :9100   │ │  :8080   │ │  :9115   │ │  :9104   │           │
│  └────┬─────┘ └────┬─────┘ └────┬─────┘ └────┬─────┘           │
│       │            │            │            │                  │
│  ┌────▼────┐ ┌─────▼────┐ ┌────▼────┐ ┌─────▼────┐            │
│  │  Redis  │ │  Nginx   │ │ Custom  │ │  App     │            │
│  │ Exporter│ │ Exporter │ │ Exporter│ │ Metrics  │            │
│  │  :9121  │ │  :9113   │ │  :9000  │ │  :8000   │            │
│  └────┬────┘ └────┬─────┘ └────┬────┘ └────┬─────┘            │
│       │            │            │            │                  │
│  ═════╪════════════╪════════════╪════════════╪══════════════    │
│       │            │            │            │                  │
│  存储层:            │            │            │                  │
│  ┌────▼────────────▼────────────▼────────────▼──────────────┐   │
│  │           Prometheus Server (:9090)                       │   │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐      │   │
│  │  │  TSDB存储    │  │  告警规则    │  │  录制规则    │      │   │
│  │  │  30天保留    │  │  Recording  │  │  Rules      │      │   │
│  │  └─────────────┘  └─────────────┘  └─────────────┘      │   │
│  └──────────────────────────┬───────────────────────────────┘   │
│                              │                                  │
│  告警层:                    │                                  │
│  ┌──────────────────────────▼───────────────────────────────┐   │
│  │           AlertManager (:9093)                            │   │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐               │   │
│  │  │  邮件    │  │  钉钉    │  │  企业微信 │               │   │
│  │  │  通知    │  │  Webhook │  │  Webhook │               │   │
│  │  └──────────┘  └──────────┘  └──────────┘               │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                 │
│  可视化层:                                                       │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │           Grafana (:3000)                                │   │
│  │  ┌────────┐ ┌────────┐ ┌────────┐ ┌────────┐           │   │
│  │  │ 主机   │ │ 容器   │ │ 应用   │ │ 业务   │           │   │
│  │  │ 仪表盘 │ │ 仪表盘 │ │ 仪表盘 │ │ 仪表盘 │           │   │
│  │  └────────┘ └────────┘ └────────┘ └────────┘           │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                 │
│  日志层:                                                         │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐      │
│  │   Promtail   │───▶│     Loki     │───▶│   Grafana    │      │
│  │  (日志采集)  │    │  (日志存储)  │    │  (日志查询)  │      │
│  └──────────────┘    └──────────────┘    └──────────────┘      │
└─────────────────────────────────────────────────────────────────┘
```

---

## 🚀 一键部署

### docker-compose.yml

```yaml
version: '3.8'

# ============================================
# 企业级监控告警系统 - Docker Compose
# ============================================

services:
  # ========== Prometheus ==========
  prometheus:
    image: prom/prometheus:v2.48.0
    container_name: prometheus
    restart: always
    ports:
      - "9090:9090"
    volumes:
      - ./prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - ./prometheus/rules:/etc/prometheus/rules:ro
      - prometheus-data:/prometheus
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.path=/prometheus'
      - '--storage.tsdb.retention.time=30d'
      - '--storage.tsdb.retention.size=10GB'
      - '--web.enable-lifecycle'
      - '--web.enable-admin-api'
    networks:
      - monitoring
    deploy:
      resources:
        limits:
          cpus: '2.0'
          memory: 4G
        reservations:
          cpus: '0.5'
          memory: 1G
    healthcheck:
      test: ["CMD", "wget", "--spider", "-q", "http://localhost:9090/-/healthy"]
      interval: 30s
      timeout: 10s
      retries: 3

  # ========== Grafana ==========
  grafana:
    image: grafana/grafana:10.2.2
    container_name: grafana
    restart: always
    ports:
      - "3000:3000"
    environment:
      - GF_SECURITY_ADMIN_USER=admin
      - GF_SECURITY_ADMIN_PASSWORD=Admin@2024
      - GF_USERS_ALLOW_SIGN_UP=false
      - GF_SERVER_ROOT_URL=http://localhost:3000
      - GF_INSTALL_PLUGINS=grafana-clock-panel,grafana-piechart-panel
      - GF_ALERTING_ENABLED=true
      - GF_UNIFIED_ALERTING_ENABLED=true
    volumes:
      - grafana-data:/var/lib/grafana
      - ./grafana/provisioning:/etc/grafana/provisioning:ro
      - ./grafana/dashboards:/var/lib/grafana/dashboards:ro
    networks:
      - monitoring
    deploy:
      resources:
        limits:
          cpus: '1.0'
          memory: 1G

  # ========== AlertManager ==========
  alertmanager:
    image: prom/alertmanager:v0.26.0
    container_name: alertmanager
    restart: always
    ports:
      - "9093:9093"
    volumes:
      - ./alertmanager/alertmanager.yml:/etc/alertmanager/alertmanager.yml:ro
      - ./alertmanager/templates:/etc/alertmanager/templates:ro
      - alertmanager-data:/alertmanager
    command:
      - '--config.file=/etc/alertmanager/alertmanager.yml'
      - '--storage.path=/alertmanager'
    networks:
      - monitoring
    deploy:
      resources:
        limits:
          cpus: '0.5'
          memory: 256M

  # ========== Node Exporter (主机监控) ==========
  node-exporter:
    image: prom/node-exporter:v1.7.0
    container_name: node-exporter
    restart: always
    ports:
      - "9100:9100"
    volumes:
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
      - /:/rootfs:ro
    command:
      - '--path.procfs=/host/proc'
      - '--path.sysfs=/host/sys'
      - '--path.rootfs=/rootfs'
      - '--collector.filesystem.mount-points-exclude=^/(sys|proc|dev|host|etc)($$|/)'
    networks:
      - monitoring

  # ========== cAdvisor (容器监控) ==========
  cadvisor:
    image: gcr.io/cadvisor/cadvisor:v0.47.2
    container_name: cadvisor
    restart: always
    ports:
      - "8080:8080"
    volumes:
      - /:/rootfs:ro
      - /var/run:/var/run:ro
      - /sys:/sys:ro
      - /var/lib/docker/:/var/lib/docker:ro
      - /dev/disk/:/dev/disk:ro
    privileged: true
    devices:
      - /dev/kmsg:/dev/kmsg
    networks:
      - monitoring

  # ========== MySQL Exporter ==========
  mysql-exporter:
    image: prom/mysqld-exporter:v0.15.1
    container_name: mysql-exporter
    restart: always
    ports:
      - "9104:9104"
    environment:
      - DATA_SOURCE_NAME="exporter:ExportPass@(mysql:3306)/"
    command:
      - '--collect.auto_increment.columns'
      - '--collect.binlog_size'
      - '--collect.engine_innodb_status'
      - '--collect.global_status'
      - '--collect.global_variables'
      - '--collect.info_schema.innodb_metrics'
      - '--collect.info_schema.processlist'
      - '--collect.info_schema.query_response_time'
      - '--collect.info_schema.tables'
      - '--collect.info_schema.tablestats'
      - '--collect.perf_schema.eventsstatements'
      - '--collect.perf_schema.indexiowaits'
      - '--collect.perf_schema.tableiowaits'
      - '--collect.perf_schema.tablelocks'
      - '--collect.slave_status'
    networks:
      - monitoring

  # ========== Redis Exporter ==========
  redis-exporter:
    image: oliver006/redis_exporter:v1.55.0
    container_name: redis-exporter
    restart: always
    ports:
      - "9121:9121"
    environment:
      - REDIS_ADDR=redis://redis:6379
      - REDIS_PASSWORD=YourRedisPass
    networks:
      - monitoring

  # ========== Nginx Exporter ==========
  nginx-exporter:
    image: nginx/nginx-prometheus-exporter:1.1
    container_name: nginx-exporter
    restart: always
    ports:
      - "9113:9113"
    command:
      - '--nginx.scrape_uri=http://nginx/stub_status'
    networks:
      - monitoring

  # ========== Blackbox Exporter (探针监控) ==========
  blackbox-exporter:
    image: prom/blackbox-exporter:v0.24.0
    container_name: blackbox-exporter
    restart: always
    ports:
      - "9115:9115"
    volumes:
      - ./blackbox/blackbox.yml:/etc/blackbox_exporter/config.yml:ro
    networks:
      - monitoring

  # ========== Loki (日志存储) ==========
  loki:
    image: grafana/loki:2.9.3
    container_name: loki
    restart: always
    ports:
      - "3100:3100"
    volumes:
      - ./loki/loki-config.yml:/etc/loki/local-config.yaml:ro
      - loki-data:/loki
    command: -config.file=/etc/loki/local-config.yaml
    networks:
      - monitoring

  # ========== Promtail (日志采集) ==========
  promtail:
    image: grafana/promtail:2.9.3
    container_name: promtail
    restart: always
    volumes:
      - ./promtail/promtail-config.yml:/etc/promtail/config.yml:ro
      - /var/log:/var/log:ro
      - /var/lib/docker/containers:/var/lib/docker/containers:ro
      - /var/run/docker.sock:/var/run/docker.sock:ro
    command: -config.file=/etc/promtail/config.yml
    networks:
      - monitoring

networks:
  monitoring:
    driver: bridge

volumes:
  prometheus-data:
  grafana-data:
  alertmanager-data:
  loki-data:
```

---

## 📋 配置文件

### prometheus/prometheus.yml

```yaml
global:
  scrape_interval: 15s
  evaluation_interval: 15s
  scrape_timeout: 10s

rule_files:
  - "rules/*.yml"

alerting:
  alertmanagers:
    - static_configs:
        - targets: ['alertmanager:9093']
      timeout: 10s

scrape_configs:
  # Prometheus自身
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']

  # 主机监控
  - job_name: 'node-exporter'
    static_configs:
      - targets: ['node-exporter:9100']
        labels:
          environment: 'production'

  # 容器监控
  - job_name: 'cadvisor'
    static_configs:
      - targets: ['cadvisor:8080']

  # MySQL
  - job_name: 'mysql'
    static_configs:
      - targets: ['mysql-exporter:9104']

  # Redis
  - job_name: 'redis'
    static_configs:
      - targets: ['redis-exporter:9121']

  # Nginx
  - job_name: 'nginx'
    static_configs:
      - targets: ['nginx-exporter:9113']

  # HTTP探针
  - job_name: 'http-probe'
    metrics_path: /probe
    params:
      module: [http_2xx]
    static_configs:
      - targets:
        - https://your-website.com
        - https://api.your-website.com/health
        labels:
          probe_type: 'http'
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: blackbox-exporter:9115

  # TCP探针
  - job_name: 'tcp-probe'
    metrics_path: /probe
    params:
      module: [tcp_connect]
    static_configs:
      - targets:
        - mysql:3306
        - redis:6379
        labels:
          probe_type: 'tcp'
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: blackbox-exporter:9115
```

### prometheus/rules/node-alerts.yml

```yaml
groups:
  # ========== 主机告警 ==========
  - name: node-alerts
    rules:
      - alert: NodeHighCPU
        expr: 100 - (avg by(instance) (irate(node_cpu_seconds_total{mode="idle"}[5m])) * 100) > 80
        for: 5m
        labels:
          severity: warning
          team: ops
        annotations:
          summary: "CPU使用率过高 [{{ $labels.instance }}]"
          description: "节点 {{ $labels.instance }} CPU使用率超过80%，当前值: {{ $value | printf \"%.1f\" }}%"
          runbook: "https://wiki.company.com/runbook/node-high-cpu"

      - alert: NodeHighCPU_Critical
        expr: 100 - (avg by(instance) (irate(node_cpu_seconds_total{mode="idle"}[5m])) * 100) > 95
        for: 2m
        labels:
          severity: critical
          team: ops
        annotations:
          summary: "CPU使用率严重过高 [{{ $labels.instance }}]"
          description: "节点 {{ $labels.instance }} CPU使用率超过95%，需要立即处理！"

      - alert: NodeHighMemory
        expr: (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100 > 85
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "内存使用率过高 [{{ $labels.instance }}]"
          description: "节点 {{ $labels.instance }} 内存使用率 {{ $value | printf \"%.1f\" }}%"

      - alert: NodeDiskSpaceLow
        expr: (1 - node_filesystem_avail_bytes{fstype!~"tmpfs|overlay|squashfs"} / node_filesystem_size_bytes) * 100 > 85
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "磁盘空间不足 [{{ $labels.instance }}]"
          description: "节点 {{ $labels.instance }} 挂载点 {{ $labels.mountpoint }} 使用率 {{ $value | printf \"%.1f\" }}%"

      - alert: NodeDiskSpaceCritical
        expr: (1 - node_filesystem_avail_bytes{fstype!~"tmpfs|overlay|squashfs"} / node_filesystem_size_bytes) * 100 > 95
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "磁盘空间即将耗尽 [{{ $labels.instance }}]"
          description: "紧急！节点 {{ $labels.instance }} 磁盘使用率超过95%"

      - alert: NodeHighDiskIO
        expr: rate(node_disk_io_time_seconds_total[5m]) > 0.9
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "磁盘IO过高 [{{ $labels.instance }}]"
          description: "节点 {{ $labels.instance }} 磁盘 {{ $labels.device }} IO使用率超过90%"

      - alert: NodeNetworkReceiveErrors
        expr: rate(node_network_receive_errs_total[5m]) > 0
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "网络接收错误 [{{ $labels.instance }}]"
          description: "节点 {{ $labels.instance }} 网卡 {{ $labels.device }} 出现接收错误"

      - alert: NodeHighLoadAverage
        expr: node_load15 / count without(cpu, mode) (node_cpu_seconds_total{mode="idle"}) > 2
        for: 15m
        labels:
          severity: warning
        annotations:
          summary: "系统负载过高 [{{ $labels.instance }}]"
          description: "15分钟平均负载 {{ $value | printf \"%.2f\" }}，超过CPU核心数2倍"

      - alert: NodeDown
        expr: up{job="node-exporter"} == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "节点宕机 [{{ $labels.instance }}]"
          description: "节点 {{ $labels.instance }} 已离线超过1分钟"

  # ========== 容器告警 ==========
  - name: container-alerts
    rules:
      - alert: ContainerHighCPU
        expr: (sum by(pod, namespace) (rate(container_cpu_usage_seconds_total[5m])) / sum by(pod, namespace) (container_spec_cpu_quota / container_spec_cpu_period)) * 100 > 80
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "容器CPU使用率过高"
          description: "Pod {{ $labels.pod }} ({{ $labels.namespace }}) CPU使用率 {{ $value | printf \"%.1f\" }}%"

      - alert: ContainerHighMemory
        expr: (container_memory_working_set_bytes / container_spec_memory_limit_bytes) * 100 > 85
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "容器内存使用率过高"
          description: "Pod {{ $labels.pod }} ({{ $labels.namespace }}) 内存使用率 {{ $value | printf \"%.1f\" }}%"

      - alert: ContainerOOMKilled
        expr: increase(kube_pod_container_status_last_terminated_reason{reason="OOMKilled"}[1h]) > 0
        labels:
          severity: warning
        annotations:
          summary: "容器被OOM Kill"
          description: "Pod {{ $labels.pod }} ({{ $labels.namespace }}) 被OOM Kill"

      - alert: ContainerRestartLoop
        expr: increase(kube_pod_container_status_restarts_total[1h]) > 5
        labels:
          severity: warning
        annotations:
          summary: "容器频繁重启"
          description: "Pod {{ $labels.pod }} ({{ $labels.namespace }}) 1小时内重启 {{ $value }} 次"

      - alert: PodNotReady
        expr: kube_pod_status_ready{condition="true"} == 0
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "Pod未就绪"
          description: "Pod {{ $labels.pod }} ({{ $labels.namespace }}) 10分钟内未就绪"

      - alert: DeploymentReplicasMismatch
        expr: kube_deployment_spec_replicas != kube_deployment_status_ready_replicas
        for: 15m
        labels:
          severity: warning
        annotations:
          summary: "Deployment副本数不匹配"
          description: "Deployment {{ $labels.deployment }} ({{ $labels.namespace }}) 期望 {{ $value }} 个副本"

  # ========== HTTP探针告警 ==========
  - name: http-alerts
    rules:
      - alert: HTTPProbeFailed
        expr: probe_success{job="http-probe"} == 0
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "HTTP探针失败"
          description: "网站 {{ $labels.instance }} 无法访问"

      - alert: HTTPSSLExpiryWarning
        expr: (probe_ssl_earliest_cert_expiry - time()) / 86400 < 30
        for: 1h
        labels:
          severity: warning
        annotations:
          summary: "SSL证书即将过期"
          description: "网站 {{ $labels.instance }} SSL证书将在 {{ $value | printf \"%.0f\" }} 天后过期"

      - alert: HTTPSSLExpiryCritical
        expr: (probe_ssl_earliest_cert_expiry - time()) / 86400 < 7
        for: 1h
        labels:
          severity: critical
        annotations:
          summary: "SSL证书即将过期"
          description: "紧急！网站 {{ $labels.instance }} SSL证书将在 {{ $value | printf \"%.0f\" }} 天内过期"

      - alert: HTTPSlowResponse
        expr: probe_duration_seconds{job="http-probe"} > 5
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "HTTP响应缓慢"
          description: "网站 {{ $labels.instance }} 响应时间 {{ $value | printf \"%.2f\" }}s"

  # ========== MySQL告警 ==========
  - name: mysql-alerts
    rules:
      - alert: MySQLDown
        expr: mysql_up{job="mysql"} == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "MySQL宕机"
          description: "MySQL实例 {{ $labels.instance }} 已离线"

      - alert: MySQLHighConnections
        expr: mysql_global_status_threads_connected / mysql_global_variables_max_connections * 100 > 80
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "MySQL连接数过高"
          description: "MySQL连接使用率 {{ $value | printf \"%.1f\" }}%"

      - alert: MySQLSlowQueries
        expr: rate(mysql_global_status_slow_queries[5m]) > 0.1
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "MySQL慢查询过多"
          description: "MySQL每秒慢查询 {{ $value | printf \"%.2f\" }} 条"

      - alert: MySQLReplicationLag
        expr: mysql_slave_status_seconds_behind_master > 30
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "MySQL复制延迟"
          description: "MySQL从库复制延迟 {{ $value }} 秒"

  # ========== Redis告警 ==========
  - name: redis-alerts
    rules:
      - alert: RedisDown
        expr: redis_up{job="redis"} == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "Redis宕机"
          description: "Redis实例 {{ $labels.instance }} 已离线"

      - alert: RedisHighMemory
        expr: redis_memory_used_bytes / redis_memory_max_bytes * 100 > 85
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Redis内存使用率过高"
          description: "Redis内存使用率 {{ $value | printf \"%.1f\" }}%"

      - alert: RedisHighEviction
        expr: rate(redis_evicted_keys_total[5m]) > 100
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "Redis驱逐键过多"
          description: "Redis每秒驱逐 {{ $value | printf \"%.0f\" }} 个键"

      - alert: RedisConnectedClientsHigh
        expr: redis_connected_clients > 1000
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Redis连接数过高"
          description: "Redis当前连接数 {{ $value }}"

  # ========== 应用告警 ==========
  - name: app-alerts
    rules:
      - alert: AppHighErrorRate
        expr: sum(rate(http_requests_total{status=~"5.."}[5m])) / sum(rate(http_requests_total[5m])) > 0.05
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "应用错误率过高"
          description: "应用5xx错误率 {{ $value | printf \"%.2f\" }}%"

      - alert: AppHighLatency
        expr: histogram_quantile(0.95, rate(http_request_duration_seconds_bucket[5m])) > 2
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "应用P95延迟过高"
          description: "应用P95响应时间 {{ $value | printf \"%.2f\" }}s"

      - alert: AppHighLatency_P99
        expr: histogram_quantile(0.99, rate(http_request_duration_seconds_bucket[5m])) > 5
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "应用P99延迟严重"
          description: "应用P99响应时间 {{ $value | printf \"%.2f\" }}s"
```

### alertmanager/alertmanager.yml

```yaml
# ============================================
# AlertManager 配置
# ============================================

global:
  resolve_timeout: 5m
  smtp_smarthost: 'smtp.qq.com:587'
  smtp_from: 'your-email@qq.com'
  smtp_auth_username: 'your-email@qq.com'
  smtp_auth_password: 'your-smtp-password'
  smtp_require_tls: true

# 告警模板
templates:
  - '/etc/alertmanager/templates/*.tmpl'

# 路由规则
route:
  receiver: 'default-receiver'
  group_by: ['alertname', 'severity', 'namespace']
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h
  
  routes:
    # 紧急告警 - 立即通知
    - match:
        severity: critical
      receiver: 'critical-notify'
      group_wait: 10s
      repeat_interval: 1h
      
    # 警告告警
    - match:
        severity: warning
      receiver: 'warning-notify'
      repeat_interval: 4h
      
    # 特定团队告警
    - match:
        team: ops
      receiver: 'ops-team'
      
    # MySQL相关告警
    - match_re:
        alertname: 'MySQL.*'
      receiver: 'dba-team'
      
    # Kubernetes相关
    - match_re:
        alertname: 'Container.*|Pod.*|Deployment.*'
      receiver: 'k8s-team'

# 接收器配置
receivers:
  - name: 'default-receiver'
    email_configs:
      - to: 'ops-team@company.com'
        send_resolved: true

  - name: 'critical-notify'
    webhook_configs:
      # 钉钉机器人
      - url: 'http://dingtalk-webhook:8060/dingtalk/ops/send'
        send_resolved: true
    email_configs:
      - to: 'ops-team@company.com'
        send_resolved: true

  - name: 'warning-notify'
    webhook_configs:
      - url: 'http://dingtalk-webhook:8060/dingtalk/ops/send'
        send_resolved: true

  - name: 'ops-team'
    webhook_configs:
      - url: 'http://dingtalk-webhook:8060/dingtalk/ops/send'
        send_resolved: true
    email_configs:
      - to: 'ops-team@company.com'
        send_resolved: true

  - name: 'dba-team'
    webhook_configs:
      - url: 'http://dingtalk-webhook:8060/dingtalk/dba/send'
        send_resolved: true
    email_configs:
      - to: 'dba-team@company.com'
        send_resolved: true

  - name: 'k8s-team'
    webhook_configs:
      - url: 'http://dingtalk-webhook:8060/dingtalk/k8s/send'
        send_resolved: true

# 抑制规则
inhibit_rules:
  # critical告警抑制warning告警
  - source_match:
      severity: 'critical'
    target_match:
      severity: 'warning'
    equal: ['alertname', 'instance']
```

### blackbox/blackbox.yml

```yaml
# ============================================
# Blackbox Exporter 配置
# ============================================

modules:
  # HTTP探针
  http_2xx:
    prober: http
    timeout: 10s
    http:
      valid_http_versions: ["HTTP/1.1", "HTTP/2.0"]
      valid_status_codes: [200, 301, 302]
      method: GET
      follow_redirects: true
      preferred_ip_protocol: "ip4"

  # HTTPS探针
  http_post_2xx:
    prober: http
    timeout: 10s
    http:
      method: POST
      headers:
        Content-Type: application/json

  # TCP探针
  tcp_connect:
    prober: tcp
    timeout: 5s

  # ICMP探针
  icmp:
    prober: icmp
    timeout: 5s

  # DNS探针
  dns_resolve:
    prober: dns
    timeout: 5s
    dns:
      query_name: "example.com"
      query_type: "A"
```

### loki/loki-config.yml

```yaml
# ============================================
# Loki 配置
# ============================================

auth_enabled: false

server:
  http_listen_port: 3100

common:
  path_prefix: /loki
  storage:
    filesystem:
      chunks_directory: /loki/chunks
      rules_directory: /loki/rules
  replication_factor: 1
  ring:
    instance_addr: 127.0.0.1
    kvstore:
      store: inmemory

limits_config:
  reject_old_samples: true
  reject_old_samples_max_age: 168h
  max_query_series: 5000

schema_config:
  configs:
    - from: 2020-10-24
      store: tsdb
      object_store: filesystem
      schema: v13
      index:
        prefix: index_
        period: 24h

analytics:
  reporting_enabled: false
```

### promtail/promtail-config.yml

```yaml
# ============================================
# Promtail 配置 - 日志采集
# ============================================

server:
  http_listen_port: 9080

positions:
  filename: /tmp/positions.yaml

clients:
  - url: http://loki:3100/loki/api/v1/push

scrape_configs:
  # 系统日志
  - job_name: system
    static_configs:
      - targets:
          - localhost
        labels:
          job: syslog
          __path__: /var/log/syslog

  # Nginx访问日志
  - job_name: nginx-access
    static_configs:
      - targets:
          - localhost
        labels:
          job: nginx-access
          __path__: /var/log/nginx/access.log
    pipeline_stages:
      - regex:
          expression: '^(?P<remote_addr>[\w\.]+) .* \[(?P<time_local>.*)\] "(?P<method>\w+) (?P<request_uri>\S+) .* (?P<status>\d{3}) (?P<body_bytes_sent>\d+)'
      - labels:
          method:
          status:

  # Docker容器日志
  - job_name: docker
    static_configs:
      - targets:
          - localhost
        labels:
          job: docker
          __path__: /var/lib/docker/containers/*/*-json.log
    pipeline_stages:
      - docker: {}
      - json:
          expressions:
            log: log
            stream: stream
      - labels:
          stream:
      - output:
          source: log
```

---

## 📊 Grafana仪表盘配置

### 主机监控仪表盘 (Dashboard ID: 1860)

关键PromQL查询:

```promql
# CPU使用率
100 - (avg by(instance) (irate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)

# 内存使用率
(1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100

# 磁盘使用率
(1 - node_filesystem_avail_bytes{fstype!~"tmpfs|overlay"} / node_filesystem_size_bytes) * 100

# 磁盘IO
rate(node_disk_read_bytes_total[5m])
rate(node_disk_written_bytes_total[5m])

# 网络流量
rate(node_network_receive_bytes_total{device!="lo"}[5m]) * 8
rate(node_network_transmit_bytes_total{device!="lo"}[5m]) * 8

# 系统负载
node_load1
node_load5
node_load15
```

### 容器监控仪表盘 (Dashboard ID: 14282)

```promql
# 容器CPU使用率
sum(rate(container_cpu_usage_seconds_total{name!=""}[5m])) by (name) * 100

# 容器内存使用
container_memory_usage_bytes{name!=""}

# 容器网络
rate(container_network_receive_bytes_total{name!=""}[5m])
rate(container_network_transmit_bytes_total{name!=""}[5m])

# 容器重启次数
increase(container_restart_count{name!=""}[1h])
```

---

## 🔧 运维手册

### PromQL 常用查询

```promql
# ===== 基础查询 =====
# 5分钟平均CPU使用率
avg_over_time(cpu_usage_user[5m])

# 内存使用量
node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes

# 磁盘使用量
node_filesystem_size_bytes - node_filesystem_avail_bytes

# ===== 速率查询 =====
# 每秒请求数
rate(http_requests_total[5m])

# 每秒错误数
rate(http_requests_total{status=~"5.."}[5m])

# ===== 聚合查询 =====
# 按实例分组的CPU使用率
avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m]))

# Top 5 内存使用最多的容器
topk(5, container_memory_usage_bytes{name!=""})

# ===== 预测查询 =====
# 4小时后磁盘使用量预测
predict_linear(node_filesystem_avail_bytes[1h], 4*3600)
```

### 告警调优指南

| 告警规则 | 建议阈值 | for持续时间 | 说明 |
|---------|---------|------------|------|
| NodeHighCPU | > 80% | 5m | 避免瞬时波动 |
| NodeHighMemory | > 85% | 5m | 预留buffer |
| NodeDiskSpace | > 85% / 95% | 5m / 2m | 分级告警 |
| ContainerRestart | > 5次/h | 10m | 排除正常重启 |
| HTTP5xxError | > 5% | 5m | 关键业务指标 |
| SSL证书过期 | < 30天 / 7天 | 1h | 分级告警 |

---

**作者**: 企业级运维项目集
**版本**: 1.0.0
**更新时间**: 2026-05-02
