#!/bin/bash
# Redis Cluster生产级部署(3主3从)
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

# Step 1: 安装Redis
echo ""
echo ">>> Step 1: 安装Redis"
for node in ${NODES}; do
  echo "  安装 ${node}..."
  ssh ${REDIS_USER}@${node} sudo bash << EOF
    # 通过Remi仓库安装Redis(推荐生产环境使用包管理器)
    # 避免编译安装: 每台节点编译耗时长，无法统一升级管理
    yum install -y epel-release
    yum install -y yum-utils
    yum-config-manager --add-repo https://rpms.remirepo.net/enterprise/remi.repo
    yum module enable -y remi:redis-${REDIS_VERSION%.*} 2>/dev/null || true
    yum install -y redis

    # 创建目录
    mkdir -p /etc/redis /var/lib/redis /var/log/redis
    chown redis:redis /var/lib/redis /var/log/redis

    # 配置Redis
    cat > /etc/redis/redis_${PORT}.conf << REDISCONF
# === 基础配置 ===
port ${PORT}
bind 0.0.0.0
daemonize yes
pidfile /var/run/redis_${PORT}.pid
logfile /var/log/redis/redis_${PORT}.log
dir /var/lib/redis

# === 安全配置 ===
requirepass ${REDIS_PASSWORD}
masterauth ${REDIS_PASSWORD}
# [生产建议] Redis 6.0+推荐使用ACL:
# acl setuser app_user on >password ~* +get +set +del -flushdb -flushall -debug

# === 持久化(RDB+AOF) ===
save 900 1
save 300 10
save 60 10000
appendonly yes
appendfsync everysec

# === 内存策略 ===
maxmemory 12gb
maxmemory-policy volatile-lru  # 缓存场景推荐volatile-lru

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
ExecStart=/usr/bin/redis-server /etc/redis/redis_${PORT}.conf
ExecStop=/usr/bin/redis-cli -p ${PORT} shutdown
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

ssh ${REDIS_USER}@${FIRST_NODE} sudo /usr/bin/redis-cli \
  REDISCLI_AUTH=${REDIS_PASSWORD} --cluster create ${NODE_ARGS} \
  --cluster-replicas 1 --cluster-yes

# Step 3: 验证Cluster状态
echo ""
echo ">>> Step 3: 验证Cluster状态"
ssh ${REDIS_USER}@${FIRST_NODE} sudo /usr/bin/redis-cli \
  -a ${REDIS_PASSWORD} cluster info

echo ""
echo ">>> Cluster节点信息"
ssh ${REDIS_USER}@${FIRST_NODE} sudo /usr/bin/redis-cli \
  -a ${REDIS_PASSWORD} cluster nodes

echo ""
echo "=== Redis Cluster部署完成 ==="
echo "  主节点: $(echo ${NODES} | awk '{print $1,$2,$3}')"
echo "  从节点: $(echo ${NODES} | awk '{print $4,$5,$6}')"
