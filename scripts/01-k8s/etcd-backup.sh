#!/bin/bash
# etcd备份脚本 - 适用于K8s 1.31 (静态Pod模式)
# 前置条件: kubectl可访问集群, /etc/kubernetes/pki/etcd/证书存在
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

# === 参数化配置(兼容不同部署工具) ===
ETCD_CACERT="${ETCD_CACERT:-/etc/kubernetes/pki/etcd/ca.crt}"
ETCD_CERT="${ETCD_CERT:-/etc/kubernetes/pki/etcd/server.crt}"
ETCD_KEY="${ETCD_KEY:-/etc/kubernetes/pki/etcd/server.key}"
ETCD_ENDPOINT="${ETCD_ENDPOINT:-https://127.0.0.1:2379}"
BACKUP_DIR="${BACKUP_DIR:-/data/etcd-backup}"
DATE=$(date +%Y%m%d_%H%M%S)
KEEP_DAYS=7

mkdir -p ${BACKUP_DIR}

log_info "检查etcd健康状态..."
ETCDCTL_API=3 etcdctl endpoint health \
  --endpoints="${ETCD_ENDPOINT}" \
  --cacert="${ETCD_CACERT}" \
  --cert="${ETCD_CERT}" \
  --key="${ETCD_KEY}" || { log_error "etcd不健康，跳过备份"; exit 1; }

log_info "备份etcd..."
# [生产建议] etcd备份应加密存储(使用gpg或ossutil服务端加密)
# 示例: ossutil cp --encryption-type aes256 ${BACKUP_FILE} oss://...
ETCDCTL_API=3 etcdctl snapshot save ${BACKUP_DIR}/etcd-snapshot-${DATE}.db \
  --endpoints="${ETCD_ENDPOINT}" \
  --cacert="${ETCD_CACERT}" \
  --cert="${ETCD_CERT}" \
  --key="${ETCD_KEY}"

log_info "验证快照..."
ETCDCTL_API=3 etcdctl snapshot status ${BACKUP_DIR}/etcd-snapshot-${DATE}.db --write-out=table

log_info "清理过期备份..."
find ${BACKUP_DIR} -name "etcd-snapshot-*.db" -mtime +${KEEP_DAYS} -delete

# === 异地备份(OSS) ===
log_info "异地备份到OSS..."
BACKUP_FILE="etcd-snapshot-${DATE}.db"
if command -v ossutil &>/dev/null; then
  ossutil cp ${BACKUP_DIR}/${BACKUP_FILE} oss://${OSS_BUCKET:-etcd-backup}/$(date +%Y%m%d)/${BACKUP_FILE} 2>/dev/null && \
    log_ok "OSS上传成功" || \
    log_warn "OSS上传失败，请检查ossutil配置"
else
  log_info "ossutil未安装，跳过OSS上传"
  log_info "[生产建议] 安装ossutil并配置异地备份: ossutil config -e oss-cn-hangzhou.aliyuncs.com"
fi

# === 告警通知 ===
log_info "备份状态通知..."
BACKUP_SIZE=$(stat -f%z "${BACKUP_DIR}/${BACKUP_FILE}" 2>/dev/null || stat -c%s "${BACKUP_DIR}/${BACKUP_FILE}" 2>/dev/null)
if [ "${BACKUP_SIZE}" -gt 0 ] 2>/dev/null; then
  log_ok "etcd备份完成: ${BACKUP_FILE} ($(numfmt --to=iec ${BACKUP_SIZE:-0}))"
else
  log_error "etcd备份失败: 文件为空"
fi
