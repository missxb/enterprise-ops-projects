#!/bin/bash
# MySQL PITR恢复脚本(支持MGR+GTID)
# 依赖: xtrabackup, mysql 8.4, mysqlbinlog
# 前置: 全量备份存在, binlog连续完整, 目标时间点明确
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
chmod 600 "${MYSQL_CNF}"
cat > ${MYSQL_CNF} << CNF
[client]
user=root
password=${MYSQL_PASS}
CNF
trap "rm -f ${MYSQL_CNF}" EXIT

# 错误处理
trap 'log_error "脚本执行失败，行号: $LINENO"' ERR

echo "=== MySQL PITR恢复 ==="
echo "目标时间: ${TARGET_TIME}"

# Step 1: 停止MySQL
echo "Step 1: 停止MySQL..."
systemctl stop mysqld

# Step 2: 备份当前数据(安全措施)
echo "Step 2: 备份当前数据(安全措施)..."
if [ -d "${DATA_DIR}" ] && [ "$(ls -A ${DATA_DIR} 2>/dev/null)" ]; then
  cp -r ${DATA_DIR} ${DATA_DIR}.bak.$(date +%Y%m%d%H%M%S)
  echo "  已备份到 ${DATA_DIR}.bak.*"
fi

# Step 3: 清理数据目录
echo "Step 3: 清理数据目录..."
rm -rf ${DATA_DIR}/*

# Step 4: 恢复全量备份
echo "Step 4: 恢复全量备份..."
echo "  Step 4.1: prepare全量备份..."
xtrabackup --prepare --target-dir=${FULL_BACKUP}
echo "  Step 4.2: copy-back到数据目录..."
xtrabackup --copy-back --target-dir=${FULL_BACKUP}

# Step 5: 预生成binlog应用文件(在MySQL启动前完成)
echo "Step 5: 预生成binlog应用文件..."
BINLOG_SQL="/tmp/pitr_binlog_$(date +%Y%m%d%H%M%S).sql"
BINLOG_FILES=$(ls ${BINLOG_DIR}/*mysql-bin.* ${BINLOG_DIR}/mysql-bin.* 2>/dev/null | sort -V)
if [ -z "$BINLOG_FILES" ]; then
  echo "  ⚠️ 无binlog文件，跳过binlog生成"
  touch ${BINLOG_SQL}
else
  echo "  生成binlog SQL: ${BINLOG_SQL}"
  # 逐文件处理，避免命令行参数过长导致E2BIG错误
  > ${BINLOG_SQL}  # 清空输出文件
  for binlog in ${BINLOG_FILES}; do
    mysqlbinlog --stop-datetime="${TARGET_TIME}" "${binlog}" >> ${BINLOG_SQL}
  done
  echo "  binlog SQL大小: $(wc -c < ${BINLOG_SQL}) 字节"
fi
trap "rm -f ${MYSQL_CNF} ${BINLOG_SQL}" EXIT

# Step 6: 修复权限并启动MySQL
echo "Step 6: 修复权限并启动MySQL..."
chown -R mysql:mysql ${DATA_DIR}
systemctl start mysqld

# 等待MySQL就绪
echo "  等待MySQL启动..."
for i in $(seq 1 30); do
  if mysql --defaults-extra-file=${MYSQL_CNF} -e "SELECT 1" &>/dev/null; then
    echo "  MySQL已就绪"
    break
  fi
  if [ $i -eq 30 ]; then
    echo "  ❌ MySQL启动超时(30s)"
    exit 1
  fi
  sleep 1
done

# Step 7: 应用binlog到目标时间点
# [注意] GTID模式下，如果备份已包含部分binlog事务，可能报
# "GTID has already been executed"。如遇此错误，执行:
#   mysql> RESET MASTER;
#   mysql> SET GLOBAL GTID_PURGED='xxx';
# 然后重新SOURCE binlog.sql。实际PITR场景中全量备份通常在binlog之前，极少冲突。
if [ -s "${BINLOG_SQL}" ]; then
  echo "Step 7: 应用binlog到目标时间点..."
  mysql --defaults-extra-file=${MYSQL_CNF} < ${BINLOG_SQL}
  echo "  binlog应用完成"
else
  echo "Step 7: 跳过(无binlog)"
fi

# Step 8: 重启MySQL确保干净状态
echo "Step 8: 重启MySQL确保干净状态..."
systemctl restart mysqld

echo "✅ PITR恢复完成，已恢复到: ${TARGET_TIME}"
echo "  请验证数据一致性"
