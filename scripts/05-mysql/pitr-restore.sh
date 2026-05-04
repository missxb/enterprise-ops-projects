#!/bin/bash
# MySQL PITR恢复脚本
set -euo pipefail
umask 077

MYSQL_PASS="${MYSQL_PASS:?请设置MYSQL_PASS}"
FULL_BACKUP="${1:?用法: $0 <全量备份目录> <目标时间>}"
TARGET_TIME="${2:?用法: $0 <全量备份目录> <目标时间>}"
BINLOG_DIR="${3:-/data/mysql-backup/binlog}"
DATA_DIR="/var/lib/mysql"

# ⚠️ 确认恢复
echo "⚠️  警告: 此操作将清空MySQL数据目录并恢复到 ${TARGET_TIME}"
echo "   数据目录: ${DATA_DIR}"
echo "   全量备份: ${FULL_BACKUP}"
read -p "确认执行恢复? (y/N): " CONFIRM
if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
  echo "已取消恢复"
  exit 0
fi

# 创建临时配置文件避免命令行密码暴露
MYSQL_CNF=$(mktemp)
cat > ${MYSQL_CNF} << CNF
[client]
user=root
password=${MYSQL_PASS}
CNF
trap "rm -f ${MYSQL_CNF}" EXIT

echo "=== MySQL PITR恢复 ==="
echo "目标时间: ${TARGET_TIME}"

echo "Step 1: 停止MySQL..."
systemctl stop mysqld

echo "Step 2: 备份当前数据(安全措施)..."
if [ -d "${DATA_DIR}" ] && [ "$(ls -A ${DATA_DIR} 2>/dev/null)" ]; then
  cp -r ${DATA_DIR} ${DATA_DIR}.bak.$(date +%Y%m%d%H%M%S)
  echo "  已备份到 ${DATA_DIR}.bak.*"
fi

echo "Step 3: 清理数据目录..."
rm -rf ${DATA_DIR}/*

echo "Step 4: 恢复全量备份..."
# 正确顺序: prepare → copy-back → 应用binlog → 最终prepare → 启动
echo "  Step 4.1: prepare全量备份..."
xtrabackup --prepare --target-dir=${FULL_BACKUP}
echo "  Step 4.2: copy-back到数据目录..."
xtrabackup --copy-back --target-dir=${FULL_BACKUP}

echo "Step 5: 应用binlog到目标时间点..."
BINLOG_FILES=$(ls ${BINLOG_DIR}/mysql-bin.* 2>/dev/null | sort)
if [ -z "$BINLOG_FILES" ]; then
  echo "  ⚠️ 无binlog文件，跳过binlog恢复"
else
  for f in $BINLOG_FILES; do
    echo "  应用: $f"
    mysqlbinlog --stop-datetime="${TARGET_TIME}" "$f" | mysql --defaults-extra-file=${MYSQL_CNF}
  done
fi

echo "Step 5.1: 最终prepare(数据一致性)..."
xtrabackup --prepare --target-dir=${FULL_BACKUP}

echo "Step 6: 修复权限并启动..."
chown -R mysql:mysql ${DATA_DIR}
systemctl start mysqld

echo "✅ PITR恢复完成，请验证数据"
