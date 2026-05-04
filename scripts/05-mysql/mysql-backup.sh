#!/bin/bash
# MySQL全量备份脚本
set -euo pipefail
umask 077

MYSQL_USER="${MYSQL_USER:-backup}"
MYSQL_PASS="${MYSQL_PASS:?请设置MYSQL_PASS}"
BACKUP_DIR="${BACKUP_DIR:-/data/mysql-backup}"
DATE=$(date +%Y%m%d_%H%M%S)
KEEP_DAYS="${KEEP_DAYS:-30}"

# 创建临时配置文件(避免命令行密码暴露)
MYSQL_CNF=$(mktemp /tmp/mysql-XXXXXX.cnf)
trap "rm -f $MYSQL_CNF" EXIT
cat > $MYSQL_CNF << EOF
[client]
user=${MYSQL_USER}
password=${MYSQL_PASS}
EOF

mkdir -p ${BACKUP_DIR}/full ${BACKUP_DIR}/binlog

echo "=== MySQL全量备份(xtrabackup) ==="
xtrabackup --backup --defaults-extra-file=${MYSQL_CNF} \
  --target-dir=${BACKUP_DIR}/full/${DATE}

echo "=== 备份binlog ==="
CURRENT_BINLOG=$(mysql --defaults-extra-file=${MYSQL_CNF} -e "SHOW MASTER STATUS" --skip-column-names 2>/dev/null | awk '{print $1}')
mysqlbinlog --read-from-remote-server --raw --to-last-log --defaults-extra-file=${MYSQL_CNF} \
  --host=127.0.0.1 \
  ${CURRENT_BINLOG} \
  --result-file=${BACKUP_DIR}/binlog/

echo "清理过期备份..."
find ${BACKUP_DIR}/full -maxdepth 1 -type d -mtime +${KEEP_DAYS} -exec rm -rf {} \;
find ${BACKUP_DIR}/binlog -name "mysql-bin.*" -mtime +${KEEP_DAYS} -delete

echo "✅ MySQL备份完成"
