#!/bin/bash
# ELK健康检查脚本
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

ES_HOST="${ES_HOST:-localhost:9200}"

log_info "=== ELK健康检查 ==="

log_info "1. Elasticsearch状态..."
ES_HEALTH=$(curl -sk "https://${ES_HOST}/_cluster/health")
log_info "  status: $(echo $ES_HEALTH | jq -r '.status')"
log_info "  nodes: $(echo $ES_HEALTH | jq -r '.number_of_nodes')"
log_info "  shards: $(echo $ES_HEALTH | jq -r '.active_shards')"

log_info "2. 索引状态..."
curl -sk "https://${ES_HOST}/_cat/indices?v&s=index" | head -10

log_info "3. Logstash状态..."
curl -s "http://localhost:9600/_node/stats" | jq '.status' 2>/dev/null && log_ok "  ✅ Logstash运行" || log_warn "  ⚠️ Logstash未运行"

log_info "4. Kibana状态..."
curl -s "http://localhost:5601/api/status" | jq '.status.overall.level' 2>/dev/null && log_ok "  ✅ Kibana运行" || log_warn "  ⚠️ Kibana未运行"

log_info "5. 磁盘使用..."
df -h /var/lib/elasticsearch

log_ok "✅ ELK检查完成"
