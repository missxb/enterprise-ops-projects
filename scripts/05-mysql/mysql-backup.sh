#!/bin/bash
# MySQL全量备份脚本
set -euo pipefail

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
mysqlbinlog --read-from-remote-server --raw \
  --host=127.0.0.1 --user=${MYSQL_USER} --password=${MYSQL_PASS} \
  mysql-bin.000001 \
  --result-file=${BACKUP_DIR}/binlog/

echo "清理过期备份..."
find ${BACKUP_DIR}/full -maxdepth 1 -type d -mtime +${KEEP_DAYS} -exec rm -rf {} \;
find ${BACKUP_DIR}/binlog -name "mysql-bin.*" -mtime +${KEEP_DAYS} -delete

echo "✅ MySQL备份完成"
