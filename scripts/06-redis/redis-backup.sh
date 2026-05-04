#!/bin/bash
# Redis集群备份脚本
set -euo pipefail
umask 077

REDIS_PASSWORD="${REDIS_PASSWORD:?请设置REDIS_PASSWORD}"
REDIS_NODES="${REDIS_NODES:?请设置REDIS_NODES(空格分隔的IP列表)}"
REDIS_USER="${REDIS_USER:-redis}"
BACKUP_DIR="/data/redis-backup"
DATE=$(date +%Y%m%d)
KEEP_DAYS=7

mkdir -p ${BACKUP_DIR}

echo "=== Redis集群备份 ==="

for node in ${REDIS_NODES}; do
  for port in 6379; do
    echo "备份 ${node}:${port}..."
    # 记录BGSAVE前的LASTSAVE
    BEFORE=$(ssh ${REDIS_USER}@${node} "sudo REDISCLI_AUTH=${REDIS_PASSWORD} redis-cli -p ${port} LASTSAVE" 2>/dev/null)
    # 触发BGSAVE
    ssh ${REDIS_USER}@${node} "sudo REDISCLI_AUTH=${REDIS_PASSWORD} redis-cli -p ${port} BGSAVE" 2>/dev/null
    # 等待LASTSAVE变化(最多5分钟)
    MAX_WAIT=300
    WAITED=0
    while [ "$(ssh ${REDIS_USER}@${node} "sudo REDISCLI_AUTH=${REDIS_PASSWORD} redis-cli -p ${port} LASTSAVE" 2>/dev/null)" = "$BEFORE" ]; do
      sleep 1
      WAITED=$((WAITED+1))
      if [ $WAITED -ge $MAX_WAIT ]; then
        echo "  ❌ BGSAVE超时(${MAX_WAIT}s)"
        exit 1
      fi
    done
    # 拷贝dump文件
    ssh ${REDIS_USER}@${node} "sudo cp /var/lib/redis/dump.rdb ${BACKUP_DIR}/dump_${node}_${port}_${DATE}.rdb" 2>/dev/null
    echo "  ✅ ${node}:${port} 备份完成"
  done
done

# 清理旧备份
find ${BACKUP_DIR} -name "dump_*.rdb" -mtime +${KEEP_DAYS} -delete

echo "✅ Redis集群备份完成: ${DATE}"
