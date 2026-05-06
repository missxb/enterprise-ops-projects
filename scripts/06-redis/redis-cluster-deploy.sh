#!/bin/bash
# Redis Cluster生产级部署(3主3从)
# 依赖: redis 7.2+, ssh(节点间免密)
# 前置: 至少6个节点, 节点间网络互通, 每个节点至少4G空闲内存
set -euo pipefail
umask 077

# === 必填参数 ===
REDIS_PASSWORD="${REDIS_PASSWORD:?请设置REDIS_PASSWORD}"
NODES="${NODES:-10.10.40.11 10.10.40.12 10.10.40.13 10.10.40.14 10.10.40.15 10.10.40.16}"
REDIS_USER="${REDIS_USER:-redis}"
PORT="${PORT:-6379}"
REDIS_VERSION="${REDIS_VERSION:-7.2.4}"

echo "=== Redis Cluster生产级部署(3主3从) ==="
echo "节点: ${NODES}"
echo "版本: Redis ${REDIS_VERSION}"
# [前置条件] 需要在目标机配置sudoers免密:
# echo "${REDIS_USER} ALL=(ALL) NOPASSWD: /usr/local/redis/bin/redis-cli, /bin/bash" > /etc/sudoers.d/redis

# === 前置检查 ===
echo ">>> 前置检查..."
errors=0

# 检查必要命令
for cmd in ssh redis-cli; do
  command -v $cmd &>/dev/null || { echo "  ❌ $cmd 未安装"; errors=$((errors+1)); }
done

# 检查节点数量(至少6个)
node_count=$(echo ${NODES} | wc -w)
if [ "${node_count}" -lt 6 ]; then
  echo "  ❌ 节点数不足(需6个,当前${node_count}个)"
  errors=$((errors+1))
fi

# 检查磁盘空间(至少10GB可用)
avail_gb=$(df -BG /opt 2>/dev/null | awk 'NR==2{print $4}' | tr -d 'G')
if [ "${avail_gb:-0}" -lt 10 ]; then
  echo "  ❌ /opt磁盘空间不足(需10GB,当前${avail_gb:-0}GB)"
  errors=$((errors+1))
fi

# 检查内存(至少4GB)
mem_gb=$(free -g | awk '/Mem:/{print $2}')
if [ "${mem_gb:-0}" -lt 4 ]; then
  echo "  ⚠️  内存不足4GB(当前${mem_gb}GB),可能影响性能"
fi

[ $errors -gt 0 ] && { echo "前置检查失败"; exit 1; }
echo "  ✅ 前置检查通过"

# Step 1: 安装Redis
echo ""
echo ">>> Step 1: 安装Redis"
for node in ${NODES}; do
  echo "  安装 ${node}..."
  ssh ${REDIS_USER}@${node} sudo bash << EOF
    # 编译安装Redis (生产环境推荐方式,避免依赖第三方仓库)
    if ! command -v redis-cli &>/dev/null; then
      echo "  编译安装Redis ${REDIS_VERSION}..."
      cd /tmp
      wget -q https://download.redis.io/releases/redis-${REDIS_VERSION}.tar.gz
      tar xzf redis-${REDIS_VERSION}.tar.gz
      cd redis-${REDIS_VERSION}
      make -j$(nproc) && make install PREFIX=/usr/local/redis
      echo 'export PATH=/usr/local/redis/bin:$PATH' > /etc/profile.d/redis.sh
      source /etc/profile.d/redis.sh
    else
      echo "  Redis已安装,跳过编译步骤"
    fi

    # 创建目录
    mkdir -p /etc/redis /var/lib/redis /var/log/redis
    chown redis:redis /var/lib/redis /var/log/redis

    # 配置Redis
    cat > /etc/redis/redis_${PORT}.conf << REDISCONF
# === 基础配置 ===
port ${PORT}
# [安全] 绑定内网IP而非0.0.0.0，避免暴露到公网
# 如需绑定所有接口，请确保有防火墙/安全组限制访问
bind ${node} 127.0.0.1
daemonize yes
pidfile /var/run/redis_${PORT}.pid
logfile /var/log/redis/redis_${PORT}.log
dir /var/lib/redis

# === 安全配置 ===
requirepass ${REDIS_PASSWORD}
masterauth ${REDIS_PASSWORD}
# [生产建议] Redis 6.0+推荐使用ACL(替代requirepass):
# acl setuser app_user on >password ~* +get +set +del -flushdb -flushall -debug

# === 持久化(RDB+AOF) ===
save 900 1
save 300 10
save 60 10000
appendonly yes
appendfsync everysec

# === 内存策略 ===
maxmemory ${REDIS_MAXMEMORY:-12gb}  # 生产环境根据节点内存调整(推荐物理内存60-70%)
# [统一] 与文档推荐一致，使用allkeys-lru防止OOM
maxmemory-policy allkeys-lru  # 所有key均可淘汰，防止OOM(文档推荐)

# === Cluster配置 ===
cluster-enabled yes
cluster-config-file nodes_${PORT}.conf
cluster-node-timeout 15000

# === 安全加固 ===
rename-command FLUSHDB ""
rename-command FLUSHALL ""
rename-command DEBUG ""
# [生产建议] 使用ACL替代rename-command

# === 性能优化 ===
tcp-backlog 511
timeout 300
tcp-keepalive 300
REDISCONF

    # 创建systemd service文件
    cat > /etc/systemd/system/redis_${PORT}.service << SVCEOF
[Unit]
Description=Redis on port ${PORT}
After=network.target
[Service]
User=redis
Group=redis
ExecStart=/usr/local/redis/bin/redis-server /etc/redis/redis_${PORT}.conf
# [修复] 使用REDISCLI_AUTH环境变量传递密码，避免在ExecStop命令行中暴露明文密码
Environment=REDISCLI_AUTH=${REDIS_PASSWORD}
ExecStop=/usr/local/redis/bin/redis-cli -p ${PORT} shutdown
Restart=always
LimitNOFILE=65535
[Install]
WantedBy=multi-user.target
SVCEOF
    systemctl daemon-reload

    # 启动Redis
    systemctl enable redis_${PORT}
    systemctl start redis_${PORT}
EOF
  echo "  ✅ ${node} Redis已安装"
done

# Step 2: 创建Cluster
echo ""
echo ">>> Step 2: 创建Redis Cluster"
FIRST_NODE=$(echo ${NODES} | awk '{print $1}')
NODE_ARGS=""
for node in ${NODES}; do
  NODE_ARGS="${NODE_ARGS} ${node}:${PORT}"
done

ssh ${REDIS_USER}@${FIRST_NODE} "sudo -E REDISCLI_AUTH=${REDIS_PASSWORD} /usr/local/redis/bin/redis-cli \
  --cluster create ${NODE_ARGS} \
  --cluster-replicas 1 --cluster-yes"

# Step 3: 验证Cluster状态
echo ""
echo ">>> Step 3: 验证Cluster状态"
ssh ${REDIS_USER}@${FIRST_NODE} "sudo -E REDISCLI_AUTH=${REDIS_PASSWORD} /usr/local/redis/bin/redis-cli cluster info"

echo ""
echo ">>> Cluster节点信息"
ssh ${REDIS_USER}@${FIRST_NODE} "sudo -E REDISCLI_AUTH=${REDIS_PASSWORD} /usr/local/redis/bin/redis-cli cluster nodes"

echo ""
echo "=== Redis Cluster部署完成 ==="
echo "  主节点: $(echo ${NODES} | awk '{print $1,$2,$3}')"
echo "  从节点: $(echo ${NODES} | awk '{print $4,$5,$6}')"
