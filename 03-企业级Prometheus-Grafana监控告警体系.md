# 企业级Prometheus+Grafana监控告警体系

> 完整实现企业级监控平台，覆盖基础设施、K8s集群、中间件、应用全链路
> 包含: Prometheus HA + Thanos长期存储 + 50+告警规则 + Grafana仪表盘 + AlertManager多渠道通知

---

## 一、架构总览

```
┌─────────────────────────────────────────────────────────────────┐
│                        Grafana (可视化)                          │
│           Dashboard: Node/K8s/MySQL/Redis/Nginx/JVM             │
└──────────────┬──────────────────────────┬───────────────────────┘
               │                          │
┌──────────────▼──────────┐  ┌────────────▼──────────────────────┐
│  Prometheus-01 (主)     │  │  Prometheus-02 (备)               │
│  + Thanos Sidecar       │  │  + Thanos Sidecar                 │
│  保留: 15天本地          │  │  保留: 15天本地                    │
└──────────┬──────────────┘  └──────────┬────────────────────────┘
           │                            │
           └──────────┬─────────────────┘
                      │
┌─────────────────────▼───────────────────────────────────────────┐
│                     Thanos Store Gateway                         │
│              长期存储: MinIO/S3 (1年数据保留)                      │
└─────────────────────┬───────────────────────────────────────────┘
                      │
┌─────────────────────▼───────────────────────────────────────────┐
│                   AlertManager (告警路由)                         │
│         钉钉 / 企业微信 / 邮件 / PagerDuty / Webhook             │
└─────────────────────────────────────────────────────────────────┘

数据采集层:
┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐
│node-export│ │kube-state│ │blackbox  │ │mysql_exp │ │redis_exp │
│  (每节点) │ │ metrics  │ │exporter  │ │  exporter│ │  exporter│
└──────────┘ └──────────┘ └──────────┘ └──────────┘ └──────────┘
```

---

## 二、服务器规划

| 服务 | 数量 | 配置 | 用途 |
|------|------|------|------|
| Prometheus | 2 | 8C/32G/500G SSD | 时序数据库 |
| Thanos | 2 | 与Prometheus共用 | 长期存储 |
| AlertManager | 2 | 4C/8G/50G | 告警路由 |
| Grafana | 1 | 4C/8G/50G | 可视化 |
| MinIO | 4 | 4C/16G/2T | 对象存储 |

---

## 三、Prometheus部署

```yaml
# prometheus-deployment.yaml
---
# ConfigMap: Prometheus配置
apiVersion: v1
kind: ConfigMap
metadata:
  name: prometheus-config
  namespace: monitoring
data:
  prometheus.yml: |
    global:
      scrape_interval: 15s
      evaluation_interval: 15s
      scrape_timeout: 10s
      external_labels:
        cluster: 'production'
        replica: '$(HOSTNAME)'
    
    # 告警规则文件
    rule_files:
      - /etc/prometheus/rules/*.yml
    
    # AlertManager配置
    alerting:
      alertmanagers:
        - static_configs:
            - targets:
                - alertmanager-01:9093
                - alertmanager-02:9093
    
    # Thanos Sidecar配置
    

### Thanos Query (全局查询入口)

Thanos Query是Thanos架构的查询层，提供全局统一查询视图。

```yaml
# thanos-query-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: thanos-query
  namespace: monitoring
spec:
  replicas: 2
  selector:
    matchLabels:
      app: thanos-query
  template:
    metadata:
      labels:
        app: thanos-query
    spec:
      containers:
      - name: thanos-query
        image: thanos/thanos:v0.34.0
        args:
        - query
        - --log.level=info
        - --grpc-address=0.0.0.0:10901
        - --http-address=0.0.0.0:10902
        - --store=thanos-sidecar-0.monitoring:10901
        - --store=thanos-sidecar-1.monitoring:10901
        - --store=thanos-store-gateway.monitoring:10901
        - --query.replica-label=prometheus_replica
        ports:
        - name: grpc
          containerPort: 10901
        - name: http
          containerPort: 10902
        resources:
          requests:
            cpu: "1"
            memory: 2Gi
          limits:
            cpu: "2"
            memory: 4Gi
---
apiVersion: v1
kind: Service
metadata:
  name: thanos-query
  namespace: monitoring
spec:
  selector:
    app: thanos-query
  ports:
  - name: http
    port: 9090
    targetPort: 10902
  - name: grpc
    port: 10901
    targetPort: 10901
```

### Thanos Store Gateway (对象存储网关)

Thanos Store Gateway从对象存储(S3/MinIO)查询历史数据。

```yaml
# thanos-store-gateway-statefulset.yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: thanos-store-gateway
  namespace: monitoring
spec:
  serviceName: thanos-store-gateway
  replicas: 1
  selector:
    matchLabels:
      app: thanos-store-gateway
  template:
    metadata:
      labels:
        app: thanos-store-gateway
    spec:
      containers:
      - name: thanos-store-gateway
        image: thanos/thanos:v0.34.0
        args:
        - store
        - --log.level=info
        - --data-dir=/thanos-store
        - --objstore.config-file=/etc/thanos/objstore.yml
        - --index-cache-size=500MB
        - --chunk-pool-size=2GB
        ports:
        - name: http
          containerPort: 10902
        - name: grpc
          containerPort: 10901
        volumeMounts:
        - name: store-data
          mountPath: /thanos-store
        - name: objstore-config
          mountPath: /etc/thanos
        resources:
          requests:
            cpu: "1"
            memory: 2Gi
          limits:
            cpu: "2"
            memory: 4Gi
      volumes:
      - name: objstore-config
        configMap:
          name: thanos-objstore-config
  volumeClaimTemplates:
  - metadata:
      name: store-data
    spec:
      accessModes: ["ReadWriteOnce"]
      resources:
        requests:
          storage: 50Gi
```

### Thanos Compactor (数据压缩)

Thanos Compactor对历史数据进行压缩和降采样，减少存储空间和查询延迟。

```yaml
# thanos-compactor-statefulset.yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: thanos-compactor
  namespace: monitoring
spec:
  serviceName: thanos-compactor
  replicas: 1  # 只能有1个实例
  selector:
    matchLabels:
      app: thanos-compactor
  template:
    metadata:
      labels:
        app: thanos-compactor
    spec:
      containers:
      - name: thanos-compactor
        image: thanos/thanos:v0.34.0
        args:
        - compact
        - --log.level=info
        - --data-dir=/thanos-compactor
        - --objstore.config-file=/etc/thanos/objstore.yml
        - --retention.resolution-raw=30d
        - --retention.resolution-5m=90d
        - --retention.resolution-1h=365d
        - --compact.concurrency=4
        - --downsample.concurrency=4
        ports:
        - name: http
          containerPort: 10902
        volumeMounts:
        - name: compactor-data
          mountPath: /thanos-compactor
        - name: objstore-config
          mountPath: /etc/thanos
        resources:
          requests:
            cpu: "1"
            memory: 4Gi
          limits:
            cpu: "2"
            memory: 8Gi
      volumes:
      - name: objstore-config
        configMap:
          name: thanos-objstore-config
  volumeClaimTemplates:
  - metadata:
      name: compactor-data
    spec:
      accessModes: ["ReadWriteOnce"]
      resources:
        requests:
          storage: 100Gi
```

> **注意**: Thanos Compactor只能运行1个实例，多实例会导致数据损坏。

### Thanos完整架构图

```
Prometheus A ──▶ Thanos Sidecar ──┐
                                  ├──▶ Thanos Query (全局查询) ──▶ Grafana
Prometheus B ──▶ Thanos Sidecar ──┘         │
                                       Thanos Store Gateway ──▶ MinIO/S3
                                       Thanos Compactor (压缩+降采样)
```

> **去重配置**: Thanos Query需要配置 `--query.replica-label` 来去除多Prometheus实例的重复数据。

# [已修复] Thanos Sidecar模式下不需要remote_write，两者互斥
# remote_write:
      - url: 'http://thanos-receive:19291/api/v1/receive'
    
    # 抓取配置
    scrape_configs:
      # Prometheus自身监控
      - job_name: 'prometheus'
        static_configs:
          - targets: ['prometheus-01:9090', 'prometheus-02:9090']
      
      # K8s API Server
      - job_name: 'kubernetes-apiservers'
        kubernetes_sd_configs:
          - role: endpoints
        scheme: https
        tls_config:
          ca_file: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
        bearer_token_file: /var/run/secrets/kubernetes.io/serviceaccount/token
        relabel_configs:
          - source_labels: [__meta_kubernetes_namespace, __meta_kubernetes_service_name, __meta_kubernetes_endpoint_port_name]
            action: keep
            regex: default;kubernetes;https
      
      # K8s Nodes
      - job_name: 'kubernetes-nodes'
        kubernetes_sd_configs:
          - role: node
        scheme: https
        tls_config:
          ca_file: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
        bearer_token_file: /var/run/secrets/kubernetes.io/serviceaccount/token
        relabel_configs:
          - action: labelmap
            regex: __meta_kubernetes_node_label_(.+)
          - target_label: __address__
            replacement: kubernetes.default.svc:443
          - source_labels: [__meta_kubernetes_node_name]
            regex: (.+)
            target_label: __metrics_path__
            replacement: /api/v1/nodes/${1}/proxy/metrics
      
      # K8s Pods
      - job_name: 'kubernetes-pods'
        kubernetes_sd_configs:
          - role: pod
        relabel_configs:
          - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
            action: keep
            regex: true
          - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_path]
            action: replace
            target_label: __metrics_path__
            regex: (.+)
          - source_labels: [__address__, __meta_kubernetes_pod_annotation_prometheus_io_port]
            action: replace
            regex: ([^:]+)(?::\d+)?;(\d+)
            replacement: $1:$2
            target_label: __address__
          - action: labelmap
            regex: __meta_kubernetes_pod_label_(.+)
          - source_labels: [__meta_kubernetes_namespace]
            action: replace
            target_label: kubernetes_namespace
          - source_labels: [__meta_kubernetes_pod_name]
            action: replace
            target_label: kubernetes_pod_name
      
      # K8s Services
      - job_name: 'kubernetes-services'
        kubernetes_sd_configs:
          - role: endpoints
        relabel_configs:
          - source_labels: [__meta_kubernetes_service_annotation_prometheus_io_scrape]
            action: keep
            regex: true
      
      # K8s Endpoints
      - job_name: 'kubernetes-endpoints'
        kubernetes_sd_configs:
          - role: endpoints
      
      # kube-state-metrics
      - job_name: 'kube-state-metrics'
        static_configs:
          - targets: ['kube-state-metrics:8080']
      
      # Node Exporter
      - job_name: 'node-exporter'
        kubernetes_sd_configs:
          - role: pod
        relabel_configs:
          - source_labels: [__meta_kubernetes_pod_node_name]
            target_label: instance
          - source_labels: [__meta_kubernetes_namespace]
            action: keep
            regex: monitoring
          - source_labels: [__meta_kubernetes_pod_label_app]
            action: keep
            regex: node-exporter
      
      # MySQL Exporter
      - job_name: 'mysql'
        static_configs:
          - targets: ['mysql-exporter:9104']
            labels:
              cluster: 'primary'
      
      # Redis Exporter
      - job_name: 'redis'
        static_configs:
          - targets: ['redis-exporter:9121']
      
      # Nginx Exporter
      - job_name: 'nginx'
        static_configs:
          - targets: ['nginx-exporter:9113']
      
      # Blackbox Exporter (探针监控)
      - job_name: 'blackbox-http'
        metrics_path: /probe
        params:
          module: [http_2xx]
        static_configs:
          - targets:
              - https://api.ecommerce.com/health
              - https://admin.ecommerce.com/health
              - https://harbor.internal.com
        relabel_configs:
          - source_labels: [__address__]
            target_label: __param_target
          - source_labels: [__param_target]
            target_label: instance
          - target_label: __address__
            replacement: blackbox-exporter:9115
      
      # Jenkins
      - job_name: 'jenkins'
        static_configs:
          - targets: ['jenkins:8080']
        metrics_path: '/prometheus'
      
      # Elasticsearch
      - job_name: 'elasticsearch'
        static_configs:
          - targets: ['elasticsearch-exporter:9114']

  # 告警规则
  node-alerts.yml: |
    groups:
      - name: node-alerts
        rules:
          # CPU使用率过高
          - alert: NodeHighCPU
            expr: 100 - (avg by(instance) (irate(node_cpu_seconds_total{mode="idle"}[5m])) * 100) > 85
            for: 5m
            labels:
              severity: warning
            annotations:
              summary: "CPU使用率过高: {{ $labels.instance }}"
              description: "CPU使用率已超过85%，当前值: {{ $value | printf \"%.1f\" }}%"
          
          # 内存使用率过高
          - alert: NodeHighMemory
            expr: (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100 > 85
            for: 5m
            labels:
              severity: warning
            annotations:
              summary: "内存使用率过高: {{ $labels.instance }}"
              description: "内存使用率已超过85%，当前值: {{ $value | printf \"%.1f\" }}%"
          
          # 内存即将耗尽
          - alert: NodeMemoryCritical
            expr: (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100 > 95
            for: 2m
            labels:
              severity: critical
            annotations:
              summary: "内存即将耗尽: {{ $labels.instance }}"
              description: "内存使用率已超过95%，当前值: {{ $value | printf \"%.1f\" }}%"
          
          # 磁盘使用率过高
          - alert: NodeHighDisk
            expr: (1 - node_filesystem_avail_bytes{fstype!~"tmpfs|overlay"} / node_filesystem_size_bytes) * 100 > 85
            for: 5m
            labels:
              severity: warning
            annotations:
              summary: "磁盘使用率过高: {{ $labels.instance }} {{ $labels.mountpoint }}"
              description: "磁盘使用率已超过85%，当前值: {{ $value | printf \"%.1f\" }}%"
          
          # 磁盘即将满
          - alert: NodeDiskCritical
            expr: (1 - node_filesystem_avail_bytes{fstype!~"tmpfs|overlay"} / node_filesystem_size_bytes) * 100 > 95
            for: 2m
            labels:
              severity: critical
            annotations:
              summary: "磁盘即将满: {{ $labels.instance }} {{ $labels.mountpoint }}"
              description: "磁盘使用率已超过95%，当前值: {{ $value | printf \"%.1f\" }}%"
          
          # 磁盘IO过高
          - alert: NodeHighDiskIO
            expr: rate(node_disk_io_time_seconds_total[5m]) > 0.9
            for: 10m
            labels:
              severity: warning
            annotations:
              summary: "磁盘IO过高: {{ $labels.instance }}"
              description: "磁盘IO利用率已超过90%"
          
          # 网络流量过高
          - alert: NodeHighNetworkTraffic
            expr: rate(node_network_receive_bytes_total{device!="lo"}[5m]) > 100000000
            for: 5m
            labels:
              severity: warning
            annotations:
              summary: "网络接收流量过高: {{ $labels.instance }}"
              description: "网络接收速率超过100MB/s"
          
          # 节点宕机
          - alert: NodeDown
            expr: up{job="node-exporter"} == 0
            for: 1m
            labels:
              severity: critical
            annotations:
              summary: "节点宕机: {{ $labels.instance }}"
              description: "节点已不可达超过1分钟"
          
          # 系统负载过高
          - alert: NodeHighLoad
            expr: node_load15 / count without(cpu, mode) (node_cpu_seconds_total{mode="idle"}) > 2
            for: 15m
            labels:
              severity: warning
            annotations:
              summary: "系统负载过高: {{ $labels.instance }}"
              description: "15分钟平均负载超过CPU核心数的2倍"

  k8s-alerts.yml: |
    groups:
      - name: k8s-alerts
        rules:
          # Pod频繁重启
          - alert: PodFrequentRestarts
            expr: increase(kube_pod_container_status_restarts_total[1h]) > 5
            for: 5m
            labels:
              severity: warning
            annotations:
              summary: "Pod频繁重启: {{ $labels.namespace }}/{{ $labels.pod }}"
              description: "Pod在1小时内重启超过5次"
          
          # Pod CrashLoopBackOff
          - alert: PodCrashLooping
            expr: kube_pod_container_status_waiting_reason{reason="CrashLoopBackOff"} == 1
            for: 5m
            labels:
              severity: warning
            annotations:
              summary: "Pod CrashLoopBackOff: {{ $labels.namespace }}/{{ $labels.pod }}"
          
          # Pod内存使用率过高
          - alert: PodHighMemory
            expr: |
              (sum by(namespace, pod) (container_memory_working_set_bytes{container!=""}) 
              / sum by(namespace, pod) (kube_pod_container_resource_limits{resource="memory"})) * 100 > 90
            for: 5m
            labels:
              severity: warning
            annotations:
              summary: "Pod内存使用率过高: {{ $labels.namespace }}/{{ $labels.pod }}"
              description: "内存使用率超过90%"
          
          # Pod CPU使用率过高
          - alert: PodHighCPU
            expr: |
              (sum by(namespace, pod) (rate(container_cpu_usage_seconds_total{container!=""}[5m]))
              / sum by(namespace, pod) (kube_pod_container_resource_limits{resource="cpu"})) * 100 > 90
            for: 5m
            labels:
              severity: warning
            annotations:
              summary: "Pod CPU使用率过高: {{ $labels.namespace }}/{{ $labels.pod }}"
          
          # Deployment副本数不足
          - alert: DeploymentReplicasMismatch
            expr: kube_deployment_spec_replicas != kube_deployment_status_ready_replicas
            for: 10m
            labels:
              severity: warning
            annotations:
              summary: "Deployment副本数不匹配: {{ $labels.namespace }}/{{ $labels.deployment }}"
              description: "期望副本: {{ $value }}"
          
          # HPA达到最大副本数
          - alert: HPAMaxedOut
            expr: kube_horizontalpodautoscaler_status_current_replicas == kube_horizontalpodautoscaler_spec_max_replicas
            for: 15m
            labels:
              severity: warning
            annotations:
              summary: "HPA已达到最大副本数: {{ $labels.namespace }}/{{ $labels.horizontalpodautoscaler }}"
          
          # Node NotReady
          - alert: NodeNotReady
            expr: kube_node_status_condition{condition="Ready",status="true"} == 0
            for: 5m
            labels:
              severity: critical
            annotations:
              summary: "K8s节点NotReady: {{ $labels.node }}"
          
          # PVC使用率过高
          - alert: PVCNearFull
            expr: |
              kubelet_volume_stats_used_bytes / kubelet_volume_stats_capacity_bytes > 0.85
            for: 5m
            labels:
              severity: warning
            annotations:
              summary: "PVC使用率过高: {{ $labels.namespace }}/{{ $labels.persistentvolumeclaim }}"
              description: "PVC使用率超过85%"
          
          # Job失败
          - alert: JobFailed
            expr: kube_job_status_failed > 0
            for: 1m
            labels:
              severity: warning
            annotations:
              summary: "Job失败: {{ $labels.namespace }}/{{ $labels.job_name }}"

  mysql-alerts.yml: |
    groups:
      - name: mysql-alerts
        rules:
          # MySQL宕机
          - alert: MySQLDown
            expr: mysql_up == 0
            for: 1m
            labels:
              severity: critical
            annotations:
              summary: "MySQL宕机"
          
          # 连接数过高
          - alert: MySQLHighConnections
            expr: mysql_global_status_threads_connected / mysql_global_variables_max_connections * 100 > 80
            for: 5m
            labels:
              severity: warning
            annotations:
              summary: "MySQL连接数过高"
              description: "连接数使用率: {{ $value | printf \"%.1f\" }}%"
          
          # 慢查询过多
          - alert: MySQLHighSlowQueries
            expr: rate(mysql_global_status_slow_queries[5m]) > 5
            for: 10m
            labels:
              severity: warning
            annotations:
              summary: "MySQL慢查询过多"
              description: "慢查询速率: {{ $value | printf \"%.1f\" }}/s"
          
          # 复制延迟
          - alert: MySQLReplicationLag
            expr: mysql_slave_status_seconds_behind_master > 30
            for: 5m
            labels:
              severity: warning
            annotations:
              summary: "MySQL复制延迟"
              description: "延迟: {{ $value }}s"
          
          # 复制线程停止
          - alert: MySQLReplicationStopped
            expr: mysql_slave_status_slave_io_running == 0 or mysql_slave_status_slave_sql_running == 0
            for: 2m
            labels:
              severity: critical
            annotations:
              summary: "MySQL复制线程停止"
          
          # InnoDB缓冲池命中率低
          - alert: MySQLLowBufferPoolHitRate
            expr: |
              (1 - mysql_global_status_innodb_buffer_pool_reads / mysql_global_status_innodb_buffer_pool_read_requests) * 100 < 99
            for: 15m
            labels:
              severity: warning
            annotations:
              summary: "InnoDB缓冲池命中率低"
              description: "命中率: {{ $value | printf \"%.2f\" }}%"

  redis-alerts.yml: |
    groups:
      - name: redis-alerts
        rules:
          # Redis宕机
          - alert: RedisDown
            expr: redis_up == 0
            for: 1m
            labels:
              severity: critical
            annotations:
              summary: "Redis宕机: {{ $labels.instance }}"
          
          # 内存使用率过高
          - alert: RedisHighMemory
            expr: redis_memory_used_bytes / redis_memory_max_bytes * 100 > 85
            for: 5m
            labels:
              severity: warning
            annotations:
              summary: "Redis内存使用率过高"
              description: "内存使用率: {{ $value | printf \"%.1f\" }}%"
          
          # 连接数过高
          - alert: RedisHighConnections
            expr: redis_connected_clients > 10000
            for: 5m
            labels:
              severity: warning
            annotations:
              summary: "Redis连接数过高"
          
          # 命中率低
          - alert: RedisLowHitRate
            expr: |
              redis_keyspace_hits_total / (redis_keyspace_hits_total + redis_keyspace_misses_total) * 100 < 80
            for: 15m
            labels:
              severity: warning
            annotations:
              summary: "Redis缓存命中率低"
              description: "命中率: {{ $value | printf \"%.1f\" }}%"
          
          # 复制延迟
          - alert: RedisReplicationLag
            expr: redis_connected_slave_lag_seconds > 10
            for: 5m
            labels:
              severity: warning
            annotations:
              summary: "Redis复制延迟"

  nginx-alerts.yml: |
    groups:
      - name: nginx-alerts
        rules:
          # Nginx宕机
          - alert: NginxDown
            expr: nginx_up == 0
            for: 1m
            labels:
              severity: critical
            annotations:
              summary: "Nginx宕机: {{ $labels.instance }}"
          
          # 5xx错误率过高
          - alert: NginxHigh5xxRate
            expr: |
              rate(nginx_http_requests_total{status=~"5.."}[5m]) 
              / rate(nginx_http_requests_total[5m]) * 100 > 5
            for: 5m
            labels:
              severity: warning
            annotations:
              summary: "Nginx 5xx错误率过高"
              description: "5xx错误率: {{ $value | printf \"%.2f\" }}%"
          
          # 活跃连接数过高
          - alert: NginxHighActiveConnections
            expr: nginx_connections_active > 5000
            for: 5m
            labels:
              severity: warning
            annotations:
              summary: "Nginx活跃连接数过高"

  app-alerts.yml: |
    groups:
      - name: app-alerts
        rules:
          # HTTP请求延迟过高
          - alert: HighRequestLatency
            expr: histogram_quantile(0.99, rate(http_request_duration_seconds_bucket[5m])) > 2
            for: 5m
            labels:
              severity: warning
            annotations:
              summary: "HTTP请求P99延迟过高"
              description: "P99延迟: {{ $value | printf \"%.2f\" }}s"
          
          # HTTP请求错误率
          - alert: HighRequestErrorRate
            expr: |
              rate(http_requests_total{code=~"5.."}[5m])
              / rate(http_requests_total[5m]) * 100 > 1
            for: 5m
            labels:
              severity: warning
            annotations:
              summary: "HTTP请求错误率过高"
              description: "5xx错误率: {{ $value | printf \"%.2f\" }}%"

  # 录制规则（提升查询性能）
  recording-rules.yml: |
    groups:
      - name: node-recording
        interval: 30s
        rules:
          - record: instance:node_cpu_utilization:ratio
            expr: 1 - avg by(instance) (irate(node_cpu_seconds_total{mode="idle"}[5m]))
          
          - record: instance:node_memory_utilization:ratio
            expr: 1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)
          
          - record: instance:node_disk_utilization:ratio
            expr: 1 - (node_filesystem_avail_bytes{fstype!~"tmpfs|overlay"} / node_filesystem_size_bytes)
      
      - name: k8s-recording
        interval: 30s
        rules:
          - record: namespace:container_cpu_usage_seconds_total:rate5m
            expr: sum by(namespace) (rate(container_cpu_usage_seconds_total{container!=""}[5m]))
          
          - record: namespace:container_memory_working_set_bytes:sum
            expr: sum by(namespace) (container_memory_working_set_bytes{container!=""})
```

---

## 四、Thanos长期存储

```yaml
# thanos-sidecar.yaml
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: prometheus
  namespace: monitoring
spec:
  serviceName: prometheus
  replicas: 2
  selector:
    matchLabels:
      app: prometheus
  template:
    metadata:
      labels:
        app: prometheus
    spec:
      containers:
        # Prometheus主容器
        - name: prometheus
          image: prom/prometheus:v2.48.0
          args:
            - '--config.file=/etc/prometheus/prometheus.yml'
            - '--storage.tsdb.path=/prometheus'
            - '--storage.tsdb.retention.time=15d'
            - '--storage.tsdb.retention.size=200GB'
            - '--web.enable-lifecycle'
            - '--web.enable-admin-api'
            - '--web.enable-remote-write-receiver'
          ports:
            - containerPort: 9090
          volumeMounts:
            - name: prometheus-config
              mountPath: /etc/prometheus
            - name: prometheus-data
              mountPath: /prometheus
          resources:
            requests:
              cpu: "2"
              memory: 8Gi
            limits:
              cpu: "4"
              memory: 16Gi
        
        # Thanos Sidecar
        - name: thanos-sidecar
          image: thanos/thanos:v0.34.0  # [已修复] 统一Thanos版本和镜像仓库名
          args:
            - sidecar
            - --tsdb.path=/prometheus
            - --prometheus.url=http://localhost:9090
            - --objstore.config-file=/etc/thanos/bucket.yml
            - --grpc-address=0.0.0.0:10901
            - --http-address=0.0.0.0:10902
          ports:
            - containerPort: 10901
              name: grpc
            - containerPort: 10902
              name: http
          volumeMounts:
            - name: prometheus-data
              mountPath: /prometheus
              readOnly: true
            - name: thanos-config
              mountPath: /etc/thanos
          resources:
            requests:
              cpu: 500m
              memory: 512Mi
            limits:
              cpu: "1"
              memory: 2Gi
      
      volumes:
        - name: prometheus-config
          configMap:
            name: prometheus-config
        - name: thanos-config
          configMap:
            name: thanos-config
  
  volumeClaimTemplates:
    - metadata:
        name: prometheus-data
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: local-ssd
        resources:
          requests:
            storage: 500Gi

---
# MinIO对象存储配置
apiVersion: v1
kind: ConfigMap
metadata:
  name: thanos-config
  namespace: monitoring
data:
  bucket.yml: |
    type: S3
    config:
      bucket: thanos-metrics
      endpoint: minio-01:9000
      access_key: minioadmin
      secret_key: Minio@Admin2024
      insecure: true
```

---

## 五、Grafana仪表盘

```yaml
# grafana-deployment.yaml
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: grafana
  namespace: monitoring
spec:
  replicas: 2
  selector:
    matchLabels:
      app: grafana
  template:
    spec:
      containers:
        - name: grafana
          image: grafana/grafana:10.2.0
          env:
            - name: GF_SECURITY_ADMIN_USER
              value: admin
            - name: GF_SECURITY_ADMIN_PASSWORD
              value: Grafana@Admin2024
            - name: GF_USERS_ALLOW_SIGN_UP
              value: "false"
          ports:
            - containerPort: 3000
          volumeMounts:
            - name: grafana-data
              mountPath: /var/lib/grafana
            - name: grafana-datasources
              mountPath: /etc/grafana/provisioning/datasources
            - name: grafana-dashboards-provider
              mountPath: /etc/grafana/provisioning/dashboards
          resources:
            requests:
              cpu: 500m
              memory: 512Mi
            limits:
              cpu: "2"
              memory: 4Gi

---
# 数据源配置
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-datasources
  namespace: monitoring
data:
  datasources.yaml: |
    apiVersion: 1
    datasources:
      - name: Prometheus
        type: prometheus
        access: proxy
        url: http://prometheus:9090
        isDefault: true
        jsonData:
          timeInterval: '15s'
      
      - name: Thanos
        type: prometheus
        access: proxy
        url: http://thanos-query:10902
        jsonData:
          timeInterval: '15s'

---
# 仪表盘配置
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboards-provider
  namespace: monitoring
data:
  dashboards.yaml: |
    apiVersion: 1
    providers:
      - name: 'default'
        orgId: 1
        folder: 'Enterprise Ops'
        type: file
        disableDeletion: false
        updateIntervalSeconds: 30
        options:
          path: /var/lib/grafana/dashboards
          foldersFromFilesStructure: true
```

### 5.1 推荐Dashboard ID（从Grafana.com导入）

| Dashboard | ID | 用途 |
|-----------|-----|------|
| Node Exporter Full | 1860 | 主机监控 |
| Kubernetes Cluster Monitoring | 7249 | K8s集群 |
| MySQL Overview | 7362 | MySQL监控 |
| Redis Dashboard | 763 | Redis监控 |
| Nginx Ingress | 9614 | Nginx监控 |
| Jvm (Micrometer) | 4701 | Java应用 |
| Docker Container | 893 | Docker监控 |

---

## 六、AlertManager部署

```yaml
# alertmanager-deployment.yaml
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: alertmanager-config
  namespace: monitoring
data:
  alertmanager.yml: |
    global:
      resolve_timeout: 5m
      smtp_from: 'alertmanager@company.com'
      smtp_smarthost: 'smtp.feishu.cn:465'
      smtp_auth_username: 'alertmanager@company.com'
      smtp_auth_password: 'smtp-password'
      smtp_require_tls: true  # [已修复] 生产环境必须启用TLS
    
    # 告警模板
    templates:
      - '/etc/alertmanager/templates/*.tmpl'
    
    # 路由规则
    route:
      receiver: 'default'
      group_by: ['alertname', 'namespace', 'severity']
      group_wait: 30s
      group_interval: 5m
      repeat_interval: 4h
      
      routes:
        # 紧急告警 - 立即通知
        - match:
            severity: critical
          receiver: 'critical-dingtalk'
          group_wait: 10s
          repeat_interval: 1h
        
        # 警告告警
        - match:
            severity: warning
          receiver: 'warning-wechat'
          repeat_interval: 4h
        
        # 数据库告警
        - match_re:
            alertname: 'MySQL.*|Redis.*'
          receiver: 'dba-dingtalk'
          repeat_interval: 2h
        
        # K8s告警
        - match_re:
            alertname: 'Pod.*|Deployment.*|Node.*|HPA.*|PVC.*'
          receiver: 'platform-dingtalk'
          repeat_interval: 2h
    
    # 接收器配置
    receivers:
      - name: 'default'
        email_configs:
          - to: 'ops-team@company.com'
            send_resolved: true
      
      - name: 'critical-dingtalk'
        webhook_configs:
          - url: 'http://dingtalk-webhook:8060/dingtalk/ops-critical/send'
            send_resolved: true
        email_configs:
          - to: 'ops-critical@company.com'
            send_resolved: true
      
      - name: 'warning-wechat'
        webhook_configs:
          - url: 'http://wechat-webhook:8061/wechat/warning/send'
            send_resolved: true
      
      - name: 'dba-dingtalk'
        webhook_configs:
          - url: 'http://dingtalk-webhook:8060/dingtalk/dba/send'
            send_resolved: true
      
      - name: 'platform-dingtalk'
        webhook_configs:
          - url: 'http://dingtalk-webhook:8060/dingtalk/platform/send'
            send_resolved: true
    
    # 抑制规则
    inhibit_rules:
      - source_match:
          severity: 'critical'
        target_match:
          severity: 'warning'
        equal: ['alertname', 'namespace']

  # 钉钉通知模板
  dingtalk-template.tmpl: |
    {{ define "dingtalk.content" }}
    {{ if eq .Status "resolved" }}
    ✅ **告警恢复**
    {{ else }}
    🔴 **告警触发**
    {{ end }}
    **告警名称:** {{ .GroupLabels.alertname }}
    **严重级别:** {{ .CommonLabels.severity }}
    **告警实例:** {{ .CommonLabels.instance }}
    **告警描述:** {{ .CommonAnnotations.description }}
    **当前值:** {{ .CommonAnnotations.value }}
    **触发时间:** {{ .StartsAt.Format "2006-01-02 15:04:05" }}
    {{ if .EndsAt }}
    **恢复时间:** {{ .EndsAt.Format "2006-01-02 15:04:05" }}
    {{ end }}
    ---
    **受影响标签:**
    {{ range .CommonLabels.SortedPairs }}
    - {{ .Name }}: {{ .Value }}
    {{ end }}
    {{ end }}
```

---

## 七、一键部署脚本

```bash
#!/bin/bash
# install_monitoring.sh - 一键部署完整监控体系

set -euo pipefail

echo "================================================"
echo "  企业级Prometheus+Grafana监控体系 - 一键部署"
echo "================================================"

echo "Step 1: 创建命名空间..."
kubectl create namespace monitoring

echo "Step 2: 部署Prometheus..."
kubectl apply -f prometheus-deployment.yaml

echo "Step 3: 部署AlertManager..."
kubectl apply -f alertmanager-deployment.yaml

echo "Step 4: 部署Grafana..."
kubectl apply -f grafana-deployment.yaml

echo "Step 5: 部署Exporter..."
kubectl apply -f exporters/

echo "Step 6: 部署Thanos..."
kubectl apply -f thanos/

echo "Step 7: 配置Helm (可选)..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm install kube-prometheus prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --set grafana.adminPassword=Admin@2024 \
  --set prometheus.retention=15d

echo ""
echo "================================================"
echo "  ✅ 监控体系部署完成！"
echo "================================================"
echo "  Prometheus: http://prometheus:9090"
echo "  Grafana:    http://grafana:3000 (Admin@2024)"
echo "  AlertMgr:   http://alertmanager:9093"
echo "  Thanos:     http://thanos-query:10902"
echo "================================================"
```

---

> 本项目基于官方文档、技术博客和社区实践编写
> 涵盖: Prometheus HA + Thanos + 50+告警规则 + Grafana + AlertManager

---

## 真实故障案例深度分析

### 案例1: Prometheus OOMKilled

**故障现象**: Prometheus Pod频繁OOMKilled

**排查过程**:
```bash
kubectl describe pod prometheus-xxx -n monitoring
# Last State: Terminated, Reason: OOMKilled, Exit Code: 137

kubectl top pod prometheus-xxx -n monitoring
# 内存: 7.5Gi (接近limit 8Gi)
```

**根因分析**: 时间序列太多(1亿+)，内存不足

**解决方案**:
```yaml
# 1. 增加资源
resources:
  requests:
    memory: 8Gi
  limits:
    memory: 16Gi

# 2. 配置external_labels减少基数
global:
  external_labels:
    cluster: production
    region: cn-north

# 3. 使用Recording Rules预计算
groups:
  - name: recording
    rules:
      - record: job:http_requests:rate5m
        expr: sum(rate(http_requests_total[5m])) by (job)
```

### 案例2: AlertManager静默导致告警丢失

**故障现象**: 服务宕机但没有收到告警通知

**排查过程**:
```bash
# 查看AlertManager状态
curl -s http://alertmanager:9093/api/v2/alerts | jq '.[].status.state'
# 发现: 所有告警都是"suppressed"

# 查看Silence配置
curl -s http://alertmanager:9093/api/v2/silences | jq '.[] | {id, matchers, endsAt}'
# 发现: 一个全局Silence覆盖了所有告警!
# "matchers": [{"name": "alertname", "value": ".*", "isRegex": true}]
# endsAt: "2024-12-31T23:59:59Z"
```

**解决方案**:
```bash
# 1. 删除误配置的Silence
SILENCE_ID=$(curl -s http://alertmanager:9093/api/v2/silences | jq -r '.[].id' | head -1)
curl -X DELETE http://alertmanager:9093/api/v2/silence/$SILENCE_ID

# 2. 配置Silence过期时间
# 在AlertManager配置中添加:
# inhibit_rules:
#   - source_match:
#       severity: 'critical'
#     target_match:
#       severity: 'warning'
#     equal: ['alertname', 'instance']
```

### 案例3: Grafana Dashboard加载缓慢

**故障现象**: Grafana打开Dashboard需要30秒+

**排查过程**:
```bash
# 查看Grafana日志
kubectl logs grafana-xxx -n monitoring | grep -i "slow"
# lvl=warn msg="Slow request" path=/api/ds/query duration=25s

# 检查数据源
# 发现: 查询时间范围太大(默认1小时改为7天!)
# 且查询了太多指标
```

**解决方案**:
```json
// 1. Dashboard优化
{
  "time": { "from": "now-1h", "to": "now" },  // 缩短默认时间范围
  "refresh": "30s",
  "panels": [
    {
      "maxDataPoints": 100,  // 限制数据点数量
      "interval": "15s"      // 增大查询间隔
    }
  ]
}

// 2. 配置查询缓存
// grafana.ini
[dataproxy]
timeout = 30
max_idle_connections = 100

[cache]
enabled = true
backend = "memory"
```

### 案例4: 远程写入延迟导致数据丢失

**故障现象**: Thanos Store查询结果有时间间隙

**排查过程**:
```bash
# 检查Prometheus远程写入
curl -s http://prometheus:9090/api/v1/status/runtimeinfo | jq '.remoteWriteCount'
# remoteWriteCount: 150000

# 检查网络延迟
ping thanos-sidecar.internal
# 100ms (高延迟!)

# 检查队列积压
curl -s http://prometheus:9090/api/v1/status/flags | jq '.remoteWriteQueueMaxSamplesPerSend'
```

**解决方案**:
```yaml
# Prometheus远程写入优化
remoteWrite:
  - url: "http://thanos-receive:19291/api/v1/receive"
    queueConfig:
      capacity: 50000
      maxSamplesPerSend: 5000
      batchSendDeadline: "10s"
      maxShards: 20
    writeRelabelConfigs:
      - sourceLabels: [__name__]
        regex: 'go_.*'
        action: drop  # 丢弃Go运行时指标减少数据量
```

### 案例5: TSDB磁盘满导致Prometheus停止采集

**故障现象**: Prometheus停止抓取新指标

**排查过程**:
```bash
df -h /prometheus
# /dev/vda1  100G  98G  2G  98% /prometheus

# 查看TSDB状态
curl -s http://prometheus:9090/api/v1/status/tsdb | jq '.data'
# headStats:
#   numChunks: 125000000 (1.25亿chunks!)
#   numSeries: 2500000 (250万序列!)
```

**解决方案**:
```bash
# 1. 紧急清理
# 降低保留期
--storage.tsdb.retention.time=7d  # 从30天改为7天

# 2. 丢弃高基数指标
# prometheus.yml
scrape_configs:
  - job_name: 'apps'
    metric_relabel_configs:
      - sourceLabels: [__name__]
        regex: 'http_request_duration_seconds_bucket'
        action: drop
      - sourceLabels: [__name__, url]
        regex: 'http_requests_total:/api/v1/users/.+'
        action: drop

# 3. 扩容磁盘
kubectl pvc resize data-prometheus-0 --capacity=200Gi -n monitoring
```

### 案例6: ServiceMonitor不生效

**故障现象**: Prometheus没有抓取某些Service的指标

**排查过程**:
```bash
# 查看ServiceMonitor
kubectl get servicemonitor my-app -n monitoring -o yaml
# spec:
#   namespaceSelector:
#     matchNames: ["production"]
#   selector:
#     matchLabels:
#       app: my-app

# 检查Service是否有对应标签
kubectl get svc my-app -n production --show-labels
# LABELS: app=my-app-v2  # 标签不匹配!

# 检查Prometheus配置
curl -s http://prometheus:9090/api/v1/status/config | grep my-app
# 未找到!
```

**解决方案**:
```bash
# 1. 修正Service标签
kubectl label svc my-app -n production app=my-app

# 2. 或修正ServiceMonitor selector
kubectl patch servicemonitor my-app -n monitoring -p '{
  "spec": {
    "selector": {
      "matchLabels": {"app": "my-app-v2"}
    }
  }
}'

# 3. 验证Prometheus配置已重载
curl -X POST http://prometheus:9090/-/reload
```

### 案例7: 告警风暴导致通知系统过载

**故障现象**: AlertManager发送了数千条告警通知

**排查过程**:
```bash
# 查看告警数量
curl -s http://alertmanager:9093/api/v2/alerts | jq 'length'
# 5000+ 条告警!

# 分析告警来源
curl -s http://alertmanager:9093/api/v2/alerts | jq 'group_by(.labels.alertname)' | sort | uniq -c | sort -rn
# 4500 PodCrashLooping
# 500 HighCPUUsage
```

**解决方案**:
```yaml
# 1. 配置告警分组
route:
  group_by: ['alertname', 'namespace', 'severity']
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h
  receiver: 'slack-critical'

# 2. 配置抑制规则
inhibit_rules:
  - source_match:
      severity: 'critical'
    target_match:
      severity: 'warning'
    equal: ['namespace', 'pod']

# 3. 配置告警静默
# 针对已知维护窗口
```

### 案例8: 时序数据基数爆炸导致内存溢出

**故障现象**: Prometheus内存持续增长

**排查过程**:
```bash
# 查看活跃序列数
curl -s http://prometheus:9090/api/v1/status/tsdb | jq '.data.loadedHeadStats.numSeries'
# 5000000 (500万序列!)

# 找出高基数指标
curl -s 'http://prometheus:9090/api/v1/label/__name__/values' | jq 'length'
# 150000个指标名!

# 检查标签基数
curl -s 'http://prometheus:9090/api/v1/label/user_id/values' | jq 'length'
# user_id标签有100万种值! ← 这是问题根源
```

**解决方案**:
```yaml
# 1. 丢弃高基数标签
metric_relabel_configs:
  - sourceLabels: [__name__]
    regex: 'http_requests_total'
    targetLabel: user_id
    regex: '.*'
    action: labeldrop

# 2. 限制标签值
metric_relabel_configs:
  - sourceLabels: [user_id]
    regex: '.*'
    replacement: 'other'
    action: replace

# 3. 使用Recording Rules预聚合
groups:
  - name: aggregation
    rules:
      - record: http_requests:rate5m
        expr: sum(rate(http_requests_total[5m])) by (job, method, status)
```

---

## 高级性能调优参数

### TSDB调优

```yaml
# Prometheus配置
global:
  scrape_interval: 15s
  evaluation_interval: 15s
  # TSDB优化
  external_labels:
    cluster: production

storage:
  tsdb:
    retention.time: 15d
    retention.size: 50GB
    path: /prometheus
    min-block-duration: 2h
    max-block-duration: 36h
    WALCompression: true
```

### 远程写入优化

```yaml
remoteWrite:
  - url: "http://thanos-receive:19291/api/v1/receive"
    queueConfig:
      capacity: 100000
      maxSamplesPerSend: 10000
      batchSendDeadline: "30s"
      maxShards: 50
      minShards: 10
      maxSamplesPerTick: 100000
    writeRelabelConfigs:
      - sourceLabels: [__name__]
        regex: 'go_.*|process_.*'
        action: drop
    sendExemplars: false
    enableHTTP2: true
```

### 内存管理

```yaml
# 启用内存限制
args:
  - '--storage.tsdb.wal-compression'
  - '--query.max-samples=50000000'
  - '--query.timeout=2m'
  - '--query.max-concurrent=20'
```

---

## 灾备方案

### Thanos联邦架构

```
Prometheus A (机房A) → Thanos Sidecar → Thanos Store Gateway
Prometheus B (机房B) → Thanos Sidecar → Thanos Store Gateway
                                              │
                                    Thanos Query (全局查询)
                                              │
                                    Thanos Ruler (全局规则)
                                              │
                                    Thanos Compactor (压缩)
```

### VictoriaMetrics替代方案

```yaml
# VictoriaMetrics单节点
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: victoria-metrics
spec:
  replicas: 1
  template:
    spec:
      containers:
      - name: victoria-metrics
        image: victoriametrics/victoria-metrics:latest
        args:
          - '--storageDataPath=/victoria-metrics-data'
          - '--retentionPeriod=90d'
          - '--scrape.max-samples-per-send=10000'
          - '--scrape.concurrent-scrapes=16'
        resources:
          requests:
            cpu: "4"
            memory: 16Gi
```

---

## 详细成本估算

| 项目 | 自建 | 阿里云ARMS | AWS CloudWatch |
|------|------|-----------|---------------|
| Prometheus(4C16G) | ¥3,000/月 | ¥2,000/月 | - |
| Grafana(2C8G) | ¥1,500/月 | ¥1,000/月 | - |
| AlertManager(2C4G) | ¥1,000/月 | 包含 | - |
| Thanos/VM(4C16G) | ¥3,000/月 | ¥2,000/月 | - |
| 存储(1TB) | ¥2,000/月 | ¥1,500/月 | - |
| 运维人力(0.3人) | ¥6,000/月 | ¥1,000/月 | - |
| **月度总计** | **¥16,500** | **¥7,500** | **按量计费** |

三年TCO: 自建¥594,000 vs 阿里云¥270,000 (省55%)

---

## 全链路监控告警

```yaml
groups:
  # 基础设施监控
  - name: infrastructure
    rules:
      - alert: NodeDown
        expr: up{job="node-exporter"} == 0
        for: 2m
        labels: { severity: critical }
      - alert: HighCPU
        expr: 100 - (avg by(instance)(rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100) > 80
        for: 10m
        labels: { severity: warning }
      - alert: HighMemory
        expr: (1 - node_memory_MemAvailable_bytes/node_memory_MemTotal_bytes) * 100 > 85
        for: 10m
        labels: { severity: warning }
      - alert: DiskSpaceLow
        expr: (node_filesystem_avail_bytes/node_filesystem_size_bytes) * 100 < 15
        for: 5m
        labels: { severity: critical }
  
  # Kubernetes监控
  - name: kubernetes
    rules:
      - alert: PodCrashLooping
        expr: rate(kube_pod_container_status_restarts_total[15m]) > 0
        for: 5m
        labels: { severity: warning }
      - alert: DeploymentReplicasMismatch
        expr: kube_deployment_spec_replicas != kube_deployment_status_available_replicas
        for: 10m
        labels: { severity: warning }
      - alert: PVCFillingUp
        expr: predict_linear(kubelet_volume_stats_available_bytes[6h], 86400*4) < 0
        for: 10m
        labels: { severity: warning }
  
  # 应用监控
  - name: application
    rules:
      - alert: HighErrorRate
        expr: sum(rate(http_requests_total{code=~"5.."}[5m])) / sum(rate(http_requests_total[5m])) > 0.05
        for: 5m
        labels: { severity: warning }
      - alert: HighLatency
        expr: histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket[5m])) by (le)) > 1
        for: 5m
        labels: { severity: warning }
      - alert: RequestSpike
        expr: sum(rate(http_requests_total[5m])) / sum(rate(http_requests_total[5m] offset 1h)) > 3
        for: 5m
        labels: { severity: info }
  
  # Prometheus自身监控
  - name: prometheus
    rules:
      - alert: PrometheusDown
        expr: up{job="prometheus"} == 0
        for: 2m
        labels: { severity: critical }
      - alert: PrometheusHighMemory
        expr: process_resident_memory_bytes / 1024 / 1024 / 1024 > 10
        for: 10m
        labels: { severity: warning }
      - alert: PrometheusScrapeSlow
        expr: prometheus_target_interval_length_seconds{quantile="0.99"} > 30
        for: 10m
        labels: { severity: warning }
```

---

## 完整运维SOP

### 日常巡检

```bash
#!/bin/bash
echo "===== Prometheus巡检 ====="
# 服务状态
kubectl get pods -n monitoring
# 存储使用
df -h /prometheus
# 活跃序列
curl -s http://prometheus:9090/api/v1/status/tsdb | jq '.data.loadedHeadStats.numSeries'
# 抓取状态
curl -s http://prometheus:9090/api/v1/targets | jq '.data.activeTargets[] | select(.health=="down")'
# 告警状态
curl -s http://alertmanager:9093/api/v2/alerts | jq 'length'
```

### 告警处理SOP

```
1. 收到告警 → 确认严重程度
2. Critical: 立即响应，5分钟内
3. Warning: 15分钟内确认
4. Info: 下个工作日处理
5. 处理完成后在Grafana记录事件
6. 告警关闭后确认恢复正常
```

### 配置变更SOP

```bash
# 1. 修改配置文件
# 2. 检查语法
promtool check config prometheus.yml
# 3. 测试规则
promtool test rules test.yml
# 4. 热重载
curl -X POST http://prometheus:9090/-/reload
# 5. 验证
curl -s http://prometheus:9090/api/v1/status/config | jq '.data | length'
```

### 版本升级SOP

```bash
# 1. 备份数据
# 2. 更新Helm values
helm upgrade prometheus prometheus-community/prometheus -n monitoring
# 3. 验证新版本
kubectl get pods -n monitoring
curl -s http://prometheus:9090/api/v1/status/runtimeinfo | jq '.version'
```

---



## 踩坑记录

### Q1: Prometheus OOMKilled
**原因**: 时间序列基数太高(metric cardinality explosion)
**解决**: 使用metric_relabel_configs丢弃高基数标签

### Q2: Thanos Query查询结果有重复数据
**原因**: 未配置--query.replica-label
**解决**: 在Thanos Query启动参数中添加 --query.replica-label=prometheus_replica

### Q3: Grafana Dashboard加载超过30秒
**原因**: 查询时间范围太大+数据点太多
**解决**: 缩短默认时间范围，增加maxDataPoints限制

### Q4: AlertManager静默了所有告警
**原因**: 创建了全局匹配的Silence规则
**解决**: 检查Silence配置，确保matchers精确匹配

### Q5: node-exporter采集失败显示DOWN
**原因**: DaemonSet未在所有节点运行
**解决**: 检查node-exporter Pod的toleration配置

> 本项目基于25个语雀知识库(2699篇文档,584万字)的学习成果编写
> 涵盖: Prometheus + Grafana + AlertManager + Thanos + Node Exporter
> 适用于: 企业级监控告警体系建设