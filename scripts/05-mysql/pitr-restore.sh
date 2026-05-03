#!/bin/bash
# MySQL PITR恢复脚本
set -euo pipefail
umask 077

MYSQL_PASS="${MYSQL_PASS:?请设置MYSQL_PASS}"
FULL_BACKUP="${1:?用法: $0 <全量备份目录> <目标时间>}"
TARGET_TIME="${2:?用法: $0 <全量备份目录> <目标时间>}"
DATA_DIR="/var/lib/mysql"

# 创建临时配置文件避免命令行密码暴露
MYSQL_CNF=$(mktemp)
cat > ${MYSQL_CNF} << CNF
[client]
user=root
password=${MYSQL_PASS}
CNF
trap "rm -f ${MYSQL_CNF}" EXIT

echo "=== MySQL PITR恢复 ==="
echo "全量备份: ${FULL_BACKUP}"
echo "目标时间: ${TARGET_TIME}"

echo "Step 1: 停止MySQL..."
systemctl stop mysqld

echo "Step 2: 清理数据目录..."
rm -rf ${DATA_DIR}/*

echo "Step 3: 恢复全量备份..."
xtrabackup --prepare --target-dir=${FULL_BACKUP}
xtrabackup --copy-back --target-dir=${FULL_BACKUP}

echo "Step 4: 应用binlog到目标时间点..."
mysqlbinlog --stop-datetime="${TARGET_TIME}" \
  --defaults-extra-file=${MYSQL_CNF} \
  /data/mysql-backup/binlog/mysql-bin.000001

echo "Step 5: 修复权限并启动..."
chown -R mysql:mysql ${DATA_DIR}
systemctl start mysqld

echo "✅ PITR恢复完成，请验证数据"
