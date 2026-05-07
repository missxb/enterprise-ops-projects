#!/bin/bash
# Prometheus+Grafana+AlertManager生产级部署
# 依赖: kubectl, helm
# 前置: K8s集群已就绪, 至少2个Worker节点, kube-state-metrics已部署
set -euo pipefail
umask 077

# === 回滚函数 ===
CURRENT_STEP=0
rollback() {
  local exit_code=$?
  [ $exit_code -eq 0 ] && return
  echo ""
  echo "⚠️  监控栈部署失败(Step ${CURRENT_STEP})，开始回滚..."
  case $CURRENT_STEP in
    4)
      echo "  回滚: 删除Grafana相关资源..."
      kubectl delete -n ${NAMESPACE} deployment grafana 2>/dev/null || true
      kubectl delete -n ${NAMESPACE} pvc grafana-pvc 2>/dev/null || true
      kubectl delete -n ${NAMESPACE} secret grafana-secret 2>/dev/null || true
      ;&
    3)
      echo "  回滚: 删除AlertManager..."
      kubectl delete -n ${NAMESPACE} deployment alertmanager 2>/dev/null || true
      kubectl delete -n ${NAMESPACE} configmap alertmanager-config 2>/dev/null || true
      ;&
    2)
      echo "  回滚: 删除Prometheus..."
      kubectl delete -n ${NAMESPACE} statefulset prometheus 2>/dev/null || true
      kubectl delete -n ${NAMESPACE} configmap prometheus-config prometheus-alert-rules 2>/dev/null || true
      kubectl delete -n ${NAMESPACE} service prometheus prometheus-headless 2>/dev/null || true
      kubectl delete -n ${NAMESPACE} pvc prometheus-data-prometheus-0 prometheus-data-prometheus-1 2>/dev/null || true
      ;&
    1)
      echo "  回滚: 删除命名空间 ${NAMESPACE}..."
      kubectl delete namespace ${NAMESPACE} 2>/dev/null || true
      ;;
  esac
  echo "✅ 回滚完成"
}
trap rollback ERR
NAMESPACE="${NAMESPACE:-monitoring}"
PROMETHEUS_RETENTION="${PROMETHEUS_RETENTION:-30d}"
ALERTMANAGER_URL="${ALERTMANAGER_URL:-alertmanager:9093}"  # K8s集群内服务地址

echo "=== Prometheus监控栈生产级部署 ==="

# === 前置检查 ===
echo ">>> 前置检查..."
errors=0

# 检查必要命令
for cmd in kubectl helm; do
  command -v $cmd &>/dev/null || { echo "  ❌ $cmd 未安装"; errors=$((errors+1)); }
done

# 检查磁盘空间(至少10GB可用)
avail_gb=$(df -BG /opt 2>/dev/null | awk 'NR==2{print $4}' | tr -d 'G')
if [ "${avail_gb:-0}" -lt 10 ]; then
  echo "  ❌ /opt磁盘空间不足(需10GB,当前${avail_gb:-0}GB)"
  errors=$((errors+1))
fi

# 检查内存(至少4GB)
mem_gb=$(free -g | awk '/Mem:/{print $2}')
if [ "${mem_gb:-0}" -lt 4 ]; then
  echo "  ⚠️  内存不足4GB(当前${mem_gb}GB),可能影响性能"
fi

[ $errors -gt 0 ] && { echo "前置检查失败"; exit 1; }
echo "  ✅ 前置检查通过"

# Step 1: 创建命名空间
CURRENT_STEP=1
echo ">>> Step 1: 创建命名空间"
kubectl create namespace ${NAMESPACE} --dry-run=client -o yaml | kubectl apply -f -
# 为NetworkPolicy打标签(允许production命名空间访问监控)
kubectl label namespace ${NAMESPACE} name=monitoring --overwrite

# Step 2: 部署Prometheus StatefulSet(2副本+PVC)
CURRENT_STEP=2
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
            for: 3m
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
            for: 3m
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
            for: 3m
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
CURRENT_STEP=3
echo ">>> Step 3: 部署AlertManager"
# 创建AlertManager配置
cat << ALERTMGRCONF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: alertmanager-config
  namespace: monitoring
data:
  alertmanager.yml: |
    global:
      resolve_timeout: 5m
    route:
      receiver: default
      group_by: ['alertname']
      group_wait: 30s
      group_interval: 5m
      repeat_interval: 4h
    receivers:
      - name: default
        webhook_configs:
          - url: 'http://localhost:9095/'
ALERTMGRCONF

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
CURRENT_STEP=4
echo ">>> Step 4: 部署Grafana"
# 创建Grafana Secret
kubectl create secret generic grafana-secret -n ${NAMESPACE} \
  --from-literal=admin-password="${GRAFANA_ADMIN_PASSWORD:-admin}" \
  --dry-run=client -o yaml | kubectl apply -f -

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
