#!/bin/bash
# 监控告警检查脚本
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

# 前置条件: curl, jq
command -v jq >/dev/null || { echo '❌ 需要安装jq'; exit 1; }

PROMETHEUS_URL="${PROMETHEUS_URL:-localhost:9090}"

log_info "=== 监控系统检查 ==="

log_info "1. Prometheus状态..."
curl -s "http://${PROMETHEUS_URL}/api/v1/targets" | jq '.data.activeTargets[] | select(.health=="down") | .scrapeUrl' 2>/dev/null || log_ok "  ✅ 所有target正常"

log_info "2. 活跃告警..."
ALERT_COUNT=$(curl -s "http://${PROMETHEUS_URL}/api/v1/alerts" | jq '[.data.alerts[] | select(.state=="firing")] | length')
log_info "  当前firing告警: ${ALERT_COUNT}条"

log_info "3. AlertManager状态..."
curl -s "http://localhost:9093/api/v2/alerts" | jq 'length' 2>/dev/null && log_ok "  ✅ AlertManager运行" || log_warn "  ⚠️ AlertManager未运行"

log_info "4. Grafana状态..."
curl -s "http://localhost:3000/api/health" | jq '.database' 2>/dev/null && log_ok "  ✅ Grafana运行" || log_warn "  ⚠️ Grafana未运行"

log_info "5. Thanos状态..."
curl -s "http://localhost:10902/-/healthy" >/dev/null 2>&1 && log_ok "  ✅ Thanos运行" || log_warn "  ⚠️ Thanos未运行"

log_ok "✅ 监控检查完成"
