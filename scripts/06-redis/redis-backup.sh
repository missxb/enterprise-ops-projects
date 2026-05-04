#!/bin/bash
# Redis集群备份脚本
set -euo pipefail
umask 077

REDIS_PASSWORD="${REDIS_PASSWORD:?请设置REDIS_PASSWORD}"
REDIS_NODES="${REDIS_NODES:?请设置REDIS_NODES(空格分隔的IP列表)}"
REDIS_USER="${REDIS_USER:-redis}"  # 普通用户，非root
BACKUP_DIR="/data/redis-backup"
DATE=$(date +%Y%m%d)
KEEP_DAYS=7

mkdir -p ${BACKUP_DIR}

echo "=== Redis集群备份 ==="

for node in ${REDIS_NODES}; do
  for port in 6379; do
    echo "备份 ${node}:${port}..."
    # 使用普通用户+sudo
    ssh ${REDIS_USER}@${node} "sudo redis-cli -p ${port} -a ${REDIS_PASSWORD} BGSAVE"
    sleep 5
    # 等待BGSAVE完成
    while [ "$(ssh ${REDIS_USER}@${node} "sudo redis-cli -p ${port} -a ${REDIS_PASSWORD} LASTSAVE")" = "$(ssh ${REDIS_USER}@${node} "sudo redis-cli -p ${port} -a ${REDIS_PASSWORD} LASTSAVE")" ]; do
      sleep 1
    done
    # 拷贝dump文件(使用sudo)
    ssh ${REDIS_USER}@${node} "sudo cp /var/lib/redis/dump.rdb ${BACKUP_DIR}/dump_${node}_${port}_${DATE}.rdb"
    echo "  ✅ ${node}:${port} 备份完成"
  done
done

# 清理旧备份
find ${BACKUP_DIR} -name "dump_*.rdb" -mtime +${KEEP_DAYS} -delete

echo "✅ Redis集群备份完成: ${DATE}"
