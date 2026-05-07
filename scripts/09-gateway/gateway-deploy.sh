#!/bin/bash
# K8s微服务网关完整部署脚本(Kong + Istio + Jaeger)
# 依赖: kubectl, helm, istioctl
# 前置: K8s集群已就绪, Istio已安装, Jaeger Operator已部署
set -euo pipefail
umask 077

# === 日志配置 ===
LOG_DIR="/var/log/k8s-ops"
LOG_FILE="${LOG_DIR}/$(basename $0 .sh)-$(date +%Y%m%d).log"
mkdir -p ${LOG_DIR}

log() {
    local level=$1; shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${level}] $*" | tee -a ${LOG_FILE}
}

log_info() { log "INFO" "$@"; }
log_warn() { log "WARN" "$@"; }
log_error() { log "ERROR" "$@"; }
log_ok()   { log "OK"   "$@"; }

# 错误处理
trap 'log_error "脚本执行失败，行号: $LINENO"' ERR

NAMESPACE="${NAMESPACE:-gateway}"
ISTIO_VERSION="${ISTIO_VERSION:-1.29.2}"

log_info "=== 微服务网关完整部署 ==="

# 1. 安装Kong Ingress Controller
log_info "[1/5] 部署Kong..."
helm repo add kong https://charts.konghq.com
helm repo update
helm install kong kong/kong -n ${NAMESPACE} --create-namespace \
  --set proxy.type=LoadBalancer \
  --set ingressController.enabled=true

# 2. 安装Istio(安全: 先下载校验再执行)
log_info "[2/5] 部署Istio..."
ISTIO_URL="https://github.com/istio/istio/releases/download/${ISTIO_VERSION}/istio-${ISTIO_VERSION}-linux-amd64.tar.gz"
curl -L -o /tmp/istio.tar.gz "${ISTIO_URL}"
  # 下载并校验SHA256
  curl -L -o /tmp/istio.sha256 "${ISTIO_URL}.sha256sum" 2>/dev/null || true
  if [ -f /tmp/istio.sha256 ] && [ -s /tmp/istio.sha256 ]; then
    cd /tmp && sha256sum -c istio.sha256 || { log_error "SHA256校验失败"; exit 1; }
    cd -
  else
    log_warn "SHA256校验文件不可用，跳过校验"
  fi
cd /tmp && tar xzf istio.tar.gz
cd istio-${ISTIO_VERSION}
# 使用istioctl安装(推荐方式)
  istioctl install --set profile=default -y
cd -

# 3. 安装Jaeger
log_info "[3/5] 部署Jaeger..."
kubectl apply -n ${NAMESPACE} -f - <<EOF
apiVersion: jaegertracing.io/v1
kind: Jaeger
metadata:
  name: jaeger
spec:
  strategy: production
  collector:
    maxReplicas: 3
    resources:
      limits:
        cpu: 500m
        memory: 512Mi
  storage:
    type: elasticsearch
    options:
      es:
        server-urls: http://elasticsearch:9200
        index-prefix: jaeger
  ingress:
    enabled: true
    hosts:
      - jaeger.example.com
EOF

# 4. 配置Istio Sidecar自动注入
log_info "[4/5] 启用Sidecar注入..."
kubectl label namespace ${NAMESPACE} istio-injection=enabled --overwrite

# 5. 部署示例应用
log_info "[5/5] 部署示例应用..."
kubectl apply -n ${NAMESPACE} -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: echo-server
spec:
  replicas: 2
  selector:
    matchLabels:
      app: echo-server
  template:
    metadata:
      labels:
        app: echo-server
    spec:
      containers:
        - name: echo
          image: hashicorp/http-echo
          args: ["-listen=:5678", "-text=hello"]
          ports:
            - containerPort: 5678
---
apiVersion: v1
kind: Service
metadata:
  name: echo-server
spec:
  selector:
    app: echo-server
  ports:
    - port: 5678
      targetPort: 5678
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: echo-server
spec:
  hosts: ["echo-server"]
  http:
    - route:
        - destination:
            host: echo-server
      timeout: 5s
EOF

log_ok "网关完整部署完成"
log_info "  Kong:      kubectl -n ${NAMESPACE} get svc kong-proxy"
log_info "  Istio:     istioctl analyze -n ${NAMESPACE}"
log_info "  Jaeger:    kubectl -n ${NAMESPACE} port-forward svc/jaeger-query 16686:16686"
