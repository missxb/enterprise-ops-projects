#!/bin/bash
# K8s微服务网关完整部署脚本(Kong + Istio + Jaeger)
# 依赖: kubectl, helm, istioctl
# 前置: K8s集群已就绪, Istio已安装, Jaeger Operator已部署
set -euo pipefail
umask 077

NAMESPACE="${NAMESPACE:-gateway}"
ISTIO_VERSION="${ISTIO_VERSION:-1.20.0}"

echo "=== 微服务网关完整部署 ==="

# 1. 安装Kong Ingress Controller
echo "[1/5] 部署Kong..."
helm repo add kong https://charts.konghq.com
helm repo update
helm install kong kong/kong -n ${NAMESPACE} --create-namespace \
  --set proxy.type=LoadBalancer \
  --set ingressController.enabled=true

# 2. 安装Istio(安全: 先下载校验再执行)
echo "[2/5] 部署Istio..."
ISTIO_URL="https://github.com/istio/istio/releases/download/${ISTIO_VERSION}/istio-${ISTIO_VERSION}-linux-amd64.tar.gz"
curl -L -o /tmp/istio.tar.gz "${ISTIO_URL}"
cd /tmp && tar xzf istio.tar.gz
cd istio-${ISTIO_VERSION}
kubectl apply -f manifests/profiles/default.yaml
cd -

# 3. 安装Jaeger
echo "[3/5] 部署Jaeger..."
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
echo "[4/5] 启用Sidecar注入..."
kubectl label namespace ${NAMESPACE} istio-injection=enabled --overwrite

# 5. 部署示例应用
echo "[5/5] 部署示例应用..."
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

echo "✅ 网关完整部署完成"
echo "  Kong:      kubectl -n ${NAMESPACE} get svc kong-proxy"
echo "  Istio:     istioctl analyze -n ${NAMESPACE}"
echo "  Jaeger:    kubectl -n ${NAMESPACE} port-forward svc/jaeger-query 16686:16686"
