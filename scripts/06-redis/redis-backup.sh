#!/bin/bash
# Redis集群备份脚本
# 依赖: redis-cli, cron
# 前置: Redis Cluster已部署, 备份目录可写
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

REDIS_PASSWORD="${REDIS_PASSWORD:?请设置REDIS_PASSWORD}"
REDIS_NODES="${REDIS_NODES:?请设置REDIS_NODES(空格分隔的IP列表)}"
REDIS_USER="${REDIS_USER:-redis}"
BACKUP_DIR="/data/redis-backup"
DATE=$(date +%Y%m%d)
KEEP_DAYS=7

mkdir -p ${BACKUP_DIR}

log_info "=== Redis集群备份 ==="

for node in ${REDIS_NODES}; do
  for port in 6379; do
    log_info "备份 ${node}:${port}..."
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
        log_error "  ❌ BGSAVE超时(${MAX_WAIT}s)"
        exit 1
      fi
    done
    # 拷贝dump文件
    # 动态获取RDB文件路径
    RDB_DIR=$(ssh ${REDIS_USER}@${node} "sudo REDISCLI_AUTH=${REDIS_PASSWORD} redis-cli -p ${port} CONFIG GET dir 2>/dev/null | tail -1" 2>/dev/null || echo "/var/lib/redis")
    RDB_FILE=$(ssh ${REDIS_USER}@${node} "sudo REDISCLI_AUTH=${REDIS_PASSWORD} redis-cli -p ${port} CONFIG GET dbfilename 2>/dev/null | tail -1" 2>/dev/null || echo "dump.rdb")
    ssh ${REDIS_USER}@${node} "sudo cp ${RDB_DIR}/${RDB_FILE} ${BACKUP_DIR}/dump_${node}_${port}_${DATE}.rdb" 2>/dev/null
    log_ok "  ✅ ${node}:${port} RDB备份完成"

    # 备份AOF文件(如果存在)
    AOF_FILE=$(ssh ${REDIS_USER}@${node} "sudo REDISCLI_AUTH=${REDIS_PASSWORD} redis-cli -p ${port} CONFIG GET appendfilename 2>/dev/null | tail -1" 2>/dev/null || echo "appendonly.aof")
    if ssh ${REDIS_USER}@${node} "sudo test -f ${RDB_DIR}/${AOF_FILE}" 2>/dev/null; then
      # BGREWRITEAOF确保AOF是最新的,再拷贝
      ssh ${REDIS_USER}@${node} "sudo REDISCLI_AUTH=${REDIS_PASSWORD} redis-cli -p ${port} BGREWRITEAOF" 2>/dev/null
      # 等待AOF重写完成
      MAX_AOF_WAIT=300
      AOF_WAITED=0
      while ssh ${REDIS_USER}@${node} "sudo REDISCLI_AUTH=${REDIS_PASSWORD} redis-cli -p ${port} INFO persistence 2>/dev/null" | grep -q "aof_rewrite_in_progress:1"; do
        sleep 1
        AOF_WAITED=$((AOF_WAITED+1))
        if [ $AOF_WAITED -ge $MAX_AOF_WAIT ]; then
          log_warn "  ⚠️ AOF重写超时(${MAX_AOF_WAIT}s),跳过AOF备份"
          break
        fi
      done
      ssh ${REDIS_USER}@${node} "sudo cp ${RDB_DIR}/${AOF_FILE} ${BACKUP_DIR}/appendonly_${node}_${port}_${DATE}.aof" 2>/dev/null
      log_ok "  ✅ ${node}:${port} AOF备份完成"
    else
      log_info "  ℹ️ ${node}:${port} 未启用AOF,跳过"
    fi
  done
done

# 清理旧备份
find ${BACKUP_DIR} -name "dump_*.rdb" -mtime +${KEEP_DAYS} -delete
find ${BACKUP_DIR} -name "appendonly_*.aof" -mtime +${KEEP_DAYS} -delete

log_ok "✅ Redis集群备份完成: ${DATE}"
