#!/bin/bash
# MySQL全量备份脚本
# 依赖: xtrabackup, mysql客户端
# 前置: MySQL MGR集群已部署, 备份目录可写
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

MYSQL_USER="${MYSQL_USER:-backup}"
MYSQL_PASS="${MYSQL_PASS:?请设置MYSQL_PASS}"
BACKUP_DIR="${BACKUP_DIR:-/data/mysql-backup}"
DATE=$(date +%Y%m%d_%H%M%S)
KEEP_DAYS="${KEEP_DAYS:-7}"  # 与文档一致

# 创建临时配置文件(避免命令行密码暴露)
MYSQL_CNF=$(mktemp /tmp/mysql-XXXXXX.cnf)
trap "rm -f \"$MYSQL_CNF\"" EXIT
cat > $MYSQL_CNF << EOF
[client]
user=${MYSQL_USER}
password=${MYSQL_PASS}
EOF

mkdir -p ${BACKUP_DIR}/full ${BACKUP_DIR}/binlog

# 检查xtrabackup是否安装
if ! command -v xtrabackup &>/dev/null; then
  log_warn "⚠️  xtrabackup未安装，正在安装..."
  if command -v yum &>/dev/null; then
    yum install -y https://repo.percona.com/yum/percona-release-latest.noarch.rpm
    percona-release enable-only tools
    yum install -y percona-xtrabackup-84
  elif command -v apt-get &>/dev/null; then
    apt-get install -y percona-xtrabackup-84
  else
    log_error "❌ 无法自动安装xtrabackup，请手动安装"
    exit 1
  fi
fi

log_info "=== MySQL全量备份(xtrabackup) ==="
xtrabackup --backup --defaults-extra-file=${MYSQL_CNF} \
  --target-dir=${BACKUP_DIR}/full/${DATE}

log_info "=== 备份binlog ==="
CURRENT_BINLOG=$(mysql --defaults-extra-file=${MYSQL_CNF} -e "SHOW BINARY LOG STATUS" --skip-column-names 2>/dev/null | awk '{print $1}')
mysqlbinlog --read-from-remote-server --raw --to-last-log --defaults-extra-file=${MYSQL_CNF} \
  --host=127.0.0.1 \
  ${CURRENT_BINLOG} \
  --result-file=${BACKUP_DIR}/binlog/${DATE}_

log_info "清理过期备份..."
find ${BACKUP_DIR}/full -maxdepth 1 -type d -mtime +${KEEP_DAYS} -exec rm -rf {} \;
find ${BACKUP_DIR}/binlog -name "*mysql-bin.*" -mtime +${KEEP_DAYS} -delete

# 加密备份(使用xbcrypt)
if command -v xbcrypt &>/dev/null; then
  log_info "加密备份文件..."
  ENCRYPT_KEY="${BACKUP_KEY:?请设置BACKUP_KEY用于加密}"
  for backup_dir in ${BACKUP_DIR}/full/${DATE}; do
    xbcrypt --encrypt-key="${ENCRYPT_KEY}" --encrypt-threads=4 \
      --read-stdin-from="${backup_dir}" > "${backup_dir}.xbcrypt"
    rm -rf "${backup_dir}"
    log_ok "  加密完成: ${backup_dir}.xbcrypt"
  done
else
  log_warn "xbcrypt未安装，跳过加密(生产环境建议安装percona-xtrabackup-utils)"
fi

log_ok "✅ MySQL备份完成"
