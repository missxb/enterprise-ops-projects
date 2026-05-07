#!/bin/bash
# Nginx配置测试脚本
# 依赖: nginx, curl
# 前置: Nginx+Keepalived已部署
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

BACKENDS="${BACKENDS:-10.10.50.11 10.10.50.12 10.10.50.13}"

log_info "=== Nginx配置检查 ==="

# 检查配置语法
nginx -t 2>&1 || { echo "❌ 配置语法错误"; exit 1; }

# 检查端口监听
log_info "检查80/443端口..."
ss -tlnp | grep -E ':80|:443' || echo "⚠️ 80/443端口未监听"

# 检查SSL证书
log_info "检查SSL证书..."
for cert in /etc/nginx/ssl/*.pem; do
  if [ -f "$cert" ]; then
    echo "  证书: $cert"
    openssl x509 -in "$cert" -noout -dates 2>/dev/null || echo "  ❌ 证书无效"
  fi
done

# 检查后端健康
log_info "检查后端健康..."
for backend in ${BACKENDS}; do
  curl -s -o /dev/null -w "%{http_code}" http://${backend}:8080/health || echo "  ❌ ${backend} 不可达"
done

log_ok "Nginx配置检查完成"
