#!/bin/bash
# 部署验证测试脚本
set -euo pipefail

PASS=0
FAIL=0

check() {
  local name="$1"
  local cmd="$2"
  if eval "$cmd" >/dev/null 2>&1; then
    echo "  ✅ $name"
    ((PASS++))
  else
    echo "  ❌ $name"
    ((FAIL++))
  fi
}

echo "===== K8s验证 ====="
check "kubectl可用" "kubectl version --client"
check "集群连接" "kubectl cluster-info"
check "节点就绪" "kubectl get nodes --no-headers | grep -q Ready"

echo "===== Docker验证 ====="
check "dockerd运行" "systemctl is-active docker"
check "containerd运行" "systemctl is-active containerd"

echo "===== 监控验证 ====="
check "Prometheus" "curl -sf http://localhost:9090/-/healthy"
check "AlertManager" "curl -sf http://localhost:9093/-/healthy"
check "Grafana" "curl -sf http://localhost:3000/api/health"

echo "===== 数据库验证 ====="
check "MySQL运行" "systemctl is-active mysqld"
check "MySQL连接" "mysqladmin ping -u root -p\"${MYSQL_ROOT_PASSWORD:-}\" 2>/dev/null"

echo "===== 缓存验证 ====="
check "Redis运行" "systemctl is-active redis"
check "Redis连接" "redis-cli ping 2>/dev/null | grep -q PONG"

echo "===== 日志验证 ====="
check "Elasticsearch" "curl -sf http://localhost:9200/_cluster/health"
check "Kibana" "curl -sf http://localhost:5601/api/status"

echo "===== CI/CD验证 ====="
check "Jenkins" "curl -sf http://localhost:8080/login 2>/dev/null"

echo "===== 网关验证 ====="
check "Nginx" "systemctl is-active nginx"
check "Kong" "curl -sf http://localhost:8001/status 2>/dev/null"

echo ""
echo "结果: $PASS 通过, $FAIL 失败"
[ $FAIL -eq 0 ] && echo "✅ 全部通过" || echo "❌ 有失败项"
exit $FAIL
