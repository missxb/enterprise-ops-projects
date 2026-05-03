#!/bin/bash
# 监控告警检查脚本
set -euo pipefail
umask 077

# 前置条件: curl, jq
command -v jq >/dev/null || { echo '❌ 需要安装jq'; exit 1; }

PROMETHEUS_URL="${PROMETHEUS_URL:-localhost:9090}"

echo "=== 监控系统检查 ==="

echo "1. Prometheus状态..."
curl -s "http://${PROMETHEUS_URL}/api/v1/targets" | jq '.data.activeTargets[] | select(.health=="down") | .scrapeUrl' 2>/dev/null || echo "  ✅ 所有target正常"

echo "2. 活跃告警..."
ALERT_COUNT=$(curl -s "http://${PROMETHEUS_URL}/api/v1/alerts" | jq '[.data.alerts[] | select(.state=="firing")] | length')
echo "  当前firing告警: ${ALERT_COUNT}条"

echo "3. AlertManager状态..."
curl -s "http://localhost:9093/api/v2/alerts" | jq 'length' 2>/dev/null && echo "  ✅ AlertManager运行" || echo "  ⚠️ AlertManager未运行"

echo "4. Grafana状态..."
curl -s "http://localhost:3000/api/health" | jq '.database' 2>/dev/null && echo "  ✅ Grafana运行" || echo "  ⚠️ Grafana未运行"

echo "5. Thanos状态..."
curl -s "http://localhost:10902/-/healthy" >/dev/null 2>&1 && echo "  ✅ Thanos运行" || echo "  ⚠️ Thanos未运行"

echo "✅ 监控检查完成"
