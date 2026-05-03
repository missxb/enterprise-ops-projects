#!/bin/bash
# 监控告警检查脚本
set -euo pipefail
umask 077

# 前置条件: curl, jq
command -v jq >/dev/null || { echo '❌ 需要安装jq'; exit 1; }

PROMETHEUS_URL="${PROMETHEUS_URL:-localhost:9090}"

echo "=== 监控系统检查 ==="

echo "1. Prometheus状态..."
curl -s "http://${PROMETHEUS_URL}/api/v1/targets" | jq '"health"' | head -5

echo "2. 活跃告警..."
curl -s "http://${PROMETHEUS_URL}/api/v1/alerts" | jq '"state":"firing"' | head -5

echo "3. AlertManager状态..."
curl -s "http://localhost:9093/api/v2/alerts" | head -3

echo "4. Grafana状态..."
curl -s "http://localhost:3000/api/health" || echo "  ⚠️ Grafana未运行"

echo "5. Thanos状态..."
curl -s "http://localhost:10902/-/healthy" || echo "  ⚠️ Thanos未运行"

echo "✅ 监控检查完成"
