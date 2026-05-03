#!/bin/bash
# MySQL全量备份脚本
set -euo pipefail
umask 077

MYSQL_USER="${MYSQL_USER:-backup}"
MYSQL_PASS="${MYSQL_PASS:?请设置MYSQL_PASS}"
BACKUP_DIR="/data/mysql-backup"
DATE=$(date +%Y%m%d_%H%M%S)
KEEP_DAYS=30

mkdir -p ${BACKUP_DIR}/full ${BACKUP_DIR}/binlog

echo "=== MySQL全量备份(xtrabackup) ==="
xtrabackup --backup --user=${MYSQL_USER} --password=${MYSQL_PASS} \
  --target-dir=${BACKUP_DIR}/full/${DATE}

echo "=== 备份binlog ==="
# 动态获取当前binlog文件名
CURRENT_BINLOG=$(mysql -u${MYSQL_USER} -p${MYSQL_PASS} -e "SHOW MASTER STATUS" --skip-column-names 2>/dev/null | awk '{print $1}')
mysqlbinlog --read-from-remote-server --raw --to-last-log \
  --host=127.0.0.1 --user=${MYSQL_USER} --password=${MYSQL_PASS} \
  ${CURRENT_BINLOG} \
  --result-file=${BACKUP_DIR}/binlog/

echo "清理过期备份..."
find ${BACKUP_DIR}/full -maxdepth 1 -type d -mtime +${KEEP_DAYS} -exec rm -rf {} \;
find ${BACKUP_DIR}/binlog -name "mysql-bin.*" -mtime +${KEEP_DAYS} -delete

echo "✅ MySQL备份完成"
