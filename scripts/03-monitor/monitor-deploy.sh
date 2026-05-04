#!/bin/bash
# Prometheus+Grafana+AlertManager生产级部署
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
          image: prom/prometheus:v2.48.0
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
          resources:
            requests:
              cpu: 500m
              memory: 2Gi
            limits:
              cpu: 2000m
              memory: 8Gi
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
