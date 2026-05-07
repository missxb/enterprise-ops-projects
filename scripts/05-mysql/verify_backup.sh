#!/bin/bash
# verify_backup.sh - 备份验证脚本(定期恢复演练)
# 依赖: xtrabackup
# 前置: 全量备份存在, 备份目录可写
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
log_error() { log "ERROR" "$@"; }
log_ok()   { log "OK"   "$@"; }

trap 'log_error "脚本执行失败，行号: $LINENO"' ERR

BACKUP_DIR="${BACKUP_DIR:-/data/mysql-backup}"
LATEST=$(ls -td ${BACKUP_DIR}/full/full-* 2>/dev/null | head -1)

if [ -z "${LATEST}" ]; then
  log_error "❌ 未找到全量备份"
  exit 1
fi

log_info "=== MySQL备份验证(恢复演练) ==="
log_info "验证备份: ${LATEST}"

# 1. 检查备份完整性
log_info "Step 1: prepare备份..."
xtrabackup --prepare --target-dir=${LATEST}

# 2. 验证恢复到临时目录
RESTORE_DIR="/tmp/mysql_verify_$$"
mkdir -p ${RESTORE_DIR}
log_info "Step 2: 恢复到临时目录 ${RESTORE_DIR}..."
xtrabackup --copy-back --target-dir=${LATEST} --datadir=${RESTORE_DIR}

# 3. 检查数据文件
FILE_COUNT=$(find ${RESTORE_DIR} -name "*.ibd" 2>/dev/null | wc -l)
log_info "数据文件数: ${FILE_COUNT}"

if [ "${FILE_COUNT}" -eq 0 ]; then
  log_error "❌ 未找到数据文件(.ibd)，备份可能损坏"
  rm -rf ${RESTORE_DIR}
  exit 1
fi

# 4. 检查备份元数据
if [ -f "${LATEST}/xtrabackup_info" ]; then
  log_info "备份信息:"
  grep -E "server_version|binlog_pos|uuid" ${LATEST}/xtrabackup_info | tee -a ${LOG_FILE}
fi

# 5. 清理
rm -rf ${RESTORE_DIR}

log_ok "✅ 备份验证通过: ${LATEST} (${FILE_COUNT}个数据文件)"
