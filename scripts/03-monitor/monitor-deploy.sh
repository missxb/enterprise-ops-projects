#!/bin/bash
# Prometheus+Grafana+AlertManager生产级部署
# 依赖: kubectl, helm
# 前置: K8s集群已就绪, 至少2个Worker节点, kube-state-metrics已部署
set -euo pipefail
umask 077

NAMESPACE="${NAMESPACE:-monitoring}"
PROMETHEUS_RETENTION="${PROMETHEUS_RETENTION:-30d}"
ALERTMANAGER_URL="${ALERTMANAGER_URL:-alertmanager:9093}"  # K8s集群内服务地址

echo "=== Prometheus监控栈生产级部署 ==="

# Step 1: 创建命名空间
echo ">>> Step 1: 创建命名空间"
kubectl create namespace ${NAMESPACE} --dry-run=client -o yaml | kubectl apply -f -

# Step 2: 部署Prometheus StatefulSet(2副本+PVC)
echo ">>> Step 2: 部署Prometheus HA(2副本)"
cat << 'EOF' | kubectl apply -f -
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
    alerting:
      alertmanagers:
        - static_configs:
            - targets: ['alertmanager:9093']
    rule_files:
      - /etc/prometheus/rules/*.yml
    scrape_configs:
      - job_name: 'kubernetes-nodes'
        kubernetes_sd_configs:
          - role: node
        relabel_configs:
          - source_labels: [__address__]
            regex: '(.+):(\d+)'
            target_label: __address__
            replacement: '${1}:9100'
EOF

# 创建告警规则ConfigMap
echo ">>> Step 2b: 部署Prometheus告警规则"
cat << 'RULESEOF' | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: prometheus-alert-rules
  namespace: monitoring
data:
  node-alerts.yml: |
    groups:
      - name: node-alerts
        rules:
          - alert: NodeDown
            expr: up{job="node"} == 0
            for: 1m
            labels:
              severity: critical
            annotations:
              summary: "节点 {{ $labels.instance }} 宕机"
              description: "节点已宕机超过1分钟"
          - alert: HighCPU
            expr: 100 - (avg by(instance) (irate(node_cpu_seconds_total{mode="idle"}[5m])) * 100) > 80
            for: 5m
            labels:
              severity: warning
            annotations:
              summary: "节点 {{ $labels.instance }} CPU使用率 > 80%"
          - alert: HighMemory
            expr: (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100 > 85
            for: 5m
            labels:
              severity: warning
            annotations:
              summary: "节点 {{ $labels.instance }} 内存使用率 > 85%"
          - alert: DiskSpaceLow
            expr: (node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"}) * 100 < 15
            for: 5m
            labels:
              severity: warning
            annotations:
              summary: "节点 {{ $labels.instance }} 磁盘剩余 < 15%"
      - name: app-alerts
        rules:
          - alert: PodCrashLooping
            expr: rate(kube_pod_container_status_restarts_total[15m]) * 60 * 5 > 0
            for: 5m
            labels:
              severity: critical
            annotations:
              summary: "Pod {{ $labels.pod }} CrashLoopBackOff"
          - alert: PodNotReady
            expr: kube_pod_status_ready{condition="true"} == 0
            for: 5m
            labels:
              severity: warning
            annotations:
              summary: "Pod {{ $labels.pod }} 未就绪"
      - name: mysql-alerts
        rules:
          - alert: MySQLDown
            expr: mysql_up == 0
            for: 1m
            labels:
              severity: critical
            annotations:
              summary: "MySQL实例 {{ $labels.instance }} 宕机"
          - alert: MySQLSlowQueries
            expr: rate(mysql_global_status_slow_queries[5m]) > 0.1
            for: 5m
            labels:
              severity: warning
            annotations:
              summary: "MySQL {{ $labels.instance }} 慢查询过多"
      - name: redis-alerts
        rules:
          - alert: RedisDown
            expr: redis_up == 0
            for: 1m
            labels:
              severity: critical
            annotations:
              summary: "Redis实例 {{ $labels.instance }} 宕机"
          - alert: RedisHighMemory
            expr: redis_memory_used_bytes / redis_memory_max_bytes > 0.9
            for: 5m
            labels:
              severity: warning
            annotations:
              summary: "Redis {{ $labels.instance }} 内存使用 > 90%"
RULESEOF

cat << EOF | kubectl apply -f -
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: prometheus
  namespace: monitoring
spec:
  replicas: 2
  serviceName: prometheus
  selector:
    matchLabels:
      app: prometheus
  template:
    metadata:
      labels:
        app: prometheus
    spec:
      serviceAccountName: prometheus
      containers:
        - name: prometheus
          image: prom/prometheus:v2.50.0
          args:
            - '--config.file=/etc/prometheus/prometheus.yml'
            - '--storage.tsdb.path=/prometheus'
            - '--storage.tsdb.retention.time=${PROMETHEUS_RETENTION}'
            - '--web.enable-lifecycle'
          ports:
            - containerPort: 9090
          volumeMounts:
            - name: prometheus-data
              mountPath: /prometheus
            - name: prometheus-config
              mountPath: /etc/prometheus
            - name: prometheus-alert-rules
              mountPath: /etc/prometheus/rules
              readOnly: true
          resources:
            requests:
              cpu: 500m
              memory: 2Gi
            limits:
              cpu: 2000m
              memory: 8Gi
      volumes:
        - name: prometheus-config
          configMap:
            name: prometheus-config
        - name: prometheus-alert-rules
          configMap:
            name: prometheus-alert-rules
  volumeClaimTemplates:
    - metadata:
        name: prometheus-data
      spec:
        accessModes: ["ReadWriteOnce"]
        resources:
          requests:
            storage: 100Gi
EOF

# Step 3: 部署AlertManager
echo ">>> Step 3: 部署AlertManager"
cat << EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: alertmanager
  namespace: monitoring
spec:
  replicas: 2
  selector:
    matchLabels:
      app: alertmanager
  template:
    metadata:
      labels:
        app: alertmanager
    spec:
      containers:
        - name: alertmanager
          image: prom/alertmanager:v0.26.0
          args:
            - '--config.file=/etc/alertmanager/alertmanager.yml'
          ports:
            - containerPort: 9093
          volumeMounts:
            - name: alertmanager-config
              mountPath: /etc/alertmanager
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              cpu: 500m
              memory: 1Gi
      volumes:
        - name: alertmanager-config
          configMap:
            name: alertmanager-config
EOF

# Step 4: 部署Grafana
echo ">>> Step 4: 部署Grafana"
cat << EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: grafana
  namespace: monitoring
spec:
  replicas: 1
  selector:
    matchLabels:
      app: grafana
  template:
    metadata:
      labels:
        app: grafana
    spec:
      containers:
        - name: grafana
          image: grafana/grafana:10.2.0
          env:
            - name: GF_SECURITY_ADMIN_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: grafana-secret
                  key: admin-password
          ports:
            - containerPort: 3000
          volumeMounts:
            - name: grafana-data
              mountPath: /var/lib/grafana
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              cpu: 500m
              memory: 1Gi
      volumes:
        - name: grafana-data
          persistentVolumeClaim:
            claimName: grafana-pvc
EOF

# 创建Grafana PVC
cat << PVCEOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: grafana-pvc
  namespace: monitoring
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 10Gi
  storageClassName: ${STORAGE_CLASS:-alicloud-disk-ssd}  # 可通过STORAGE_CLASS环境变量覆盖
PVCEOF

echo ""
echo "=== 监控栈部署完成 ==="
echo "  Prometheus: http://prometheus:9090"
echo "  AlertManager: http://alertmanager:9093"
echo "  Grafana: http://grafana:3000"
