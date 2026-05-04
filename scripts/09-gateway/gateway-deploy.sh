#!/bin/bash
# K8s微服务网关部署脚本(Kong + Istio)
set -euo pipefail
umask 077

NAMESPACE="${NAMESPACE:-gateway}"

echo "=== 微服务网关部署 ==="

# 1. 安装Kong Ingress Controller
echo "部署Kong..."
helm repo add kong https://charts.konghq.com
helm repo update
helm install kong kong/kong -n ${NAMESPACE} --create-namespace \
  --set proxy.type=LoadBalancer \
  --set ingressController.enabled=true

echo "✅ 网关部署完成"
