#!/bin/bash
# Redis集群备份脚本
set -euo pipefail
umask 077

REDIS_PASSWORD="${REDIS_PASSWORD:?请设置REDIS_PASSWORD}"
REDIS_NODES="${REDIS_NODES:?请设置REDIS_NODES(空格分隔的IP列表)}"
BACKUP_DIR="/data/redis-backup"
DATE=$(date +%Y%m%d)
KEEP_DAYS=7

mkdir -p ${BACKUP_DIR}

echo "=== Redis集群备份 ==="
for node in ${REDIS_NODES}; do
  for port in 6379; do
    BEFORE=$(redis-cli -h ${node} -p ${port} -a ${REDIS_PASSWORD} LASTSAVE)
    redis-cli -h ${node} -p ${port} -a ${REDIS_PASSWORD} BGSAVE
    while [ "$(redis-cli -h ${node} -p ${port} -a ${REDIS_PASSWORD} LASTSAVE)" = "$BEFORE" ]; do
      sleep 1
    done
    ssh root@${node} "cp /data/redis/dump.rdb ${BACKUP_DIR}/dump_${node}_${port}_${DATE}.rdb"
    echo "  ✅ ${node}:${port} 备份完成"
  done
done

echo "清理过期备份..."
find ${BACKUP_DIR} -name "dump_*.rdb" -mtime +${KEEP_DAYS} -delete

echo "✅ Redis备份完成"
