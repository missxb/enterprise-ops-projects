# 企业级Redis集群方案 - Cluster + Sentinel + 持久化

> 完整实现Redis高可用方案，覆盖Cluster 6节点集群、Sentinel哨兵、持久化策略、内存优化、分布式锁
> **方案说明**: 本文档同时展示Cluster和Sentinel两种方案，供读者根据实际场景二选一参考。Cluster适合大数据量分片场景，Sentinel适合中小规模简单高可用场景。
> [注意] Redis 7.0+起Sentinel支持监控Cluster节点(本项目使用Redis 7.2)。两种方案通常不混合使用，实际部署时选择其中一种即可:
> - Cluster: 适合大数据量、高并发场景，数据自动分片
> - Sentinel: 适合小数据量、简单高可用场景，数据不分片
> 适用于: 电商、社交、游戏等高并发场景
> 技术栈: Redis 7.2 Cluster + Sentinel 3节点 + Prometheus监控

---

## 一、方案对比与选型

### 1.1 三种架构对比

| 特性 | 主从复制 | Sentinel哨兵 | Redis Cluster |
|------|----------|-------------|---------------|
| 数据分片 | ❌ 不支持 | ❌ 不支持 | ✅ 16384个slot |
| 高可用 | ❌ 手动切换 | ✅ 自动故障转移 | ✅ 自动故障转移 |
| 写扩展 | ❌ 单主写入 | ❌ 单主写入 | ✅ 多主并行写入 |
| 读扩展 | ✅ 多从读取 | ✅ 多从读取 | ✅ 多主多从读取 |
| 最大数据量 | 单机内存 | 单机内存 | N × 单机内存 |
| 最大QPS | 10万+ | 10万+ | N × 10万+ |
| 运维复杂度 | ⭐ | ⭐⭐ | ⭐⭐⭐ |
| 适用场景 | 小型项目 | 中小型项目 | 大型项目 |
| 最低服务器数 | 2台 | 3台 | 6台(3主3从) |
| 月成本(参考) | ~2000元 | ~3000元 | ~12000元 |

### 1.2 选型建议

```
数据量 < 10GB + QPS < 5万 → Sentinel哨兵
数据量 > 10GB 或 QPS > 5万 → Redis Cluster
数据量 > 100GB → Redis Cluster + 集群代理(Twemproxy/Codis)
```

**选型决策树**:
- 数据量 < 10GB，简单高可用 → Sentinel (3节点Sentinel + 1主1从)
- 数据量 > 10GB，需要分片 → Cluster (6+节点，3主3从)
- 需要多key事务(MULTI/EXEC) → Sentinel (Cluster不支持跨slot事务)
- 需要Pub/Sub大规模广播 → Cluster (广播到所有节点)

### 1.3 我们的选择: Redis Cluster

理由:
- 业务数据量预估 50GB+，单机放不下
- 峰值QPS 20万+，单主扛不住
- 需要自动故障转移，减少人工干预
- 未来3年数据增长预期

---

## 二、服务器规划与成本

### 2.1 节点清单

| 角色 | 主机名 | IP | CPU | 内存 | 系统盘 | 数据盘 | Redis实例内存 | 月成本 |
|------|--------|-----|-----|------|--------|--------|-------------|--------|
| Master-01 | redis-m-01 | 10.10.40.11 | 8C | 32G | 100G SSD | 500G NVMe | 20G | 2,800元 |
| Master-02 | redis-m-02 | 10.10.40.12 | 8C | 32G | 100G SSD | 500G NVMe | 20G | 2,800元 |
| Master-03 | redis-m-03 | 10.10.40.13 | 8C | 32G | 100G SSD | 500G NVMe | 20G | 2,800元 |
| Slave-01 | redis-s-01 | 10.10.40.14 | 8C | 32G | 100G SSD | 500G NVMe | 20G | 2,800元 |
| Slave-02 | redis-s-02 | 10.10.40.15 | 8C | 32G | 100G SSD | 500G NVMe | 20G | 2,800元 |
| Slave-03 | redis-s-03 | 10.10.40.16 | 8C | 32G | 100G SSD | 500G NVMe | 20G | 2,800元 |

**总月成本: ~16,800元** (6台云服务器)
**总内存容量: 120GB** (可用数据 100GB，预留20%系统开销)
**总QPS预估: 60万+** (每主10万QPS)

### 2.2 网络规划

| 网段 | 用途 |
|------|------|
| 10.10.40.0/24 | Redis节点管理网络 |
| 内网带宽 | 10Gbps (集群内部通信) |
| 客户端连接 | 通过VIP或DNS轮询 |

---

## 三、Redis Cluster完整部署

### 3.1 系统初始化（所有Redis节点执行）

```bash
#!/bin/bash
# init_redis_nodes.sh - Redis节点系统初始化

set -euo pipefail

echo "========== 1. 关闭THP =========="
echo never > /sys/kernel/mm/transparent_hugepage/enabled
echo never > /sys/kernel/mm/transparent_hugepage/defrag
# 持久化
cat >> /etc/rc.local << 'EOF'
echo never > /sys/kernel/mm/transparent_hugepage/enabled
echo never > /sys/kernel/mm/transparent_hugepage/defrag
EOF

echo "========== 2. 优化内核参数 =========="
cat > /etc/sysctl.d/99-redis.conf << 'EOF'
# 文件描述符
fs.file-max = 655360
fs.nr_open = 655360

# TCP连接优化
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 10

# 内存优化
vm.overcommit_memory = 1
vm.swappiness = 0
vm.max_map_count = 262144

# 网络缓冲区
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
EOF
sysctl --system

echo "========== 3. 设置系统限制 =========="
cat >> /etc/security/limits.conf << 'EOF'
* soft nofile 655360
* hard nofile 655360
* soft nproc 655360
* hard nproc 655360
EOF

echo "========== 4. 创建Redis用户和目录 =========="
groupadd -r redis
useradd -r -g redis -s /sbin/nologin redis
mkdir -p /data/redis /var/log/redis /var/run/redis
chown -R redis:redis /data/redis /var/log/redis /var/run/redis

echo "========== 5. 安装Redis =========="
cd /tmp
REDIS_VERSION="7.2.4"
wget https://download.redis.io/releases/redis-${REDIS_VERSION}.tar.gz
tar xzf redis-${REDIS_VERSION}.tar.gz
cd redis-${REDIS_VERSION}
make -j$(nproc)
make install PREFIX=/usr/local/redis

# 配置PATH
echo 'export PATH=/usr/local/redis/bin:$PATH' > /etc/profile.d/redis.sh
source /etc/profile.d/redis.sh

echo "✅ Redis节点初始化完成"
redis-server --version
```

### 3.2 Redis实例配置模板

```ini
# /etc/redis/redis.conf - Redis Cluster实例配置
# 每台服务器部署1个Redis实例(端口6379)，共6台组成3主3从集群

# ===== 基础配置 =====
# 注意: 以下变量需通过 envsubst 模板化处理后再写入 redis.conf:
#   envsubst '${REDIS_BIND_IP}' < redis.conf.template > /etc/redis/redis.conf
bind 127.0.0.1 ${REDIS_BIND_IP}  # 生产环境必须绑定内网IP，禁止使用0.0.0.0
port 6379                           # 第二个实例改为6380
daemonize yes
pidfile /var/run/redis/redis_6379.pid
logfile /var/log/redis/redis_6379.log
loglevel notice
databases 16
always-show-logo no

# ===== 网络优化 =====
tcp-backlog 511
timeout 300
tcp-keepalive 300
tcp-user-timeout 60

# ===== 内存配置 =====
# [优化建议] 8C/32G服务器建议部署2个Redis实例
# 每个实例maxmemory设为物理内存的35-40%，预留系统开销
# 例: 32G服务器→2个实例→各用10G(maxmemory=10gb)
maxmemory 10gb
maxmemory-policy allkeys-lru   # 缓存场景推荐allkeys-lru(所有key均可淘汰，防止OOM)
maxmemory-samples 10           # LRU采样数，越大越精确

# ===== RDB持久化 =====
save 900 1
save 300 10
save 60 10000
stop-writes-on-bgsave-error yes
rdbcompression yes
rdbchecksum yes
dbfilename dump_6379.rdb
dir /data/redis
rdb-del-sync-files no

# ===== AOF持久化 =====
appendonly yes
appendfilename "appendonly_6379.aof"
appenddirname "appendonlydir_6379"
appendfsync everysec
no-appendfsync-on-rewrite yes
auto-aof-rewrite-percentage 100
auto-aof-rewrite-min-size 64mb
aof-use-rdb-preamble yes

# ===== 性能优化 =====
lazyfree-lazy-eviction yes
lazyfree-lazy-expire yes
lazyfree-lazy-server-del yes
lazyfree-lazy-user-del yes
lazyfree-lazy-user-flush yes
io-threads 2
# [说明] io-threads仅用于网络IO，Redis主线程仍为单线程
# 8C服务器建议2-4，不宜超过CPU核心数的一半
# io-threads在Redis 7.2中性能提升有限(官方benchmark<10%)，仅在高并发读写场景启用
io-threads-do-reads yes

# 内存碎片主动整理
activedefrag yes
active-defrag-ignore-bytes 100mb       # 碎片超过100MB才整理
active-defrag-threshold-lower 10       # 碎片率超过10%开始整理
active-defrag-threshold-upper 100      # 碎片率超过100%全速整理
active-defrag-cycle-min 1              # 最低CPU使用率1%
active-defrag-cycle-max 25             # 最高CPU使用率25%

# ===== 慢查询 =====
slowlog-log-slower-than 10000
slowlog-max-len 128

# ===== 客户端 =====
maxclients 10000
client-output-buffer-limit normal 0 0 0
client-output-buffer-limit replica 256mb 64mb 60
client-output-buffer-limit pubsub 32mb 8mb 60

# ===== 安全配置 =====
# [生产建议] Redis 6.0+推荐使用ACL替代rename-command:
# acl setuser app_user on >password ~* +get +set +del -flushdb -flushall -debug
requirepass ${REDIS_PASSWORD}  # 生产环境用envsubst或sed替换
masterauth ${REDIS_PASSWORD}  # 生产环境用envsubst或sed替换
rename-command FLUSHDB ""
rename-command FLUSHALL ""
rename-command DEBUG ""
rename-command CONFIG "CONFIG_b2c0a7e1"

# ===== Cluster核心配置 =====
cluster-enabled yes
cluster-config-file nodes_6379.conf
cluster-node-timeout 15000
cluster-require-full-coverage no  # 允许部分slot不可用时继续服务
cluster-allow-reads-when-down no  # 默认关闭，故障时可临时开启
cluster-allow-pubsub-shard-down no

# ===== 危险命令禁用 =====
rename-command KEYS "KEYS_b2c0a7e1"
rename-command SHUTDOWN "SHUTDOWN_b2c0a7e1"
rename-command REPLICAOF "REPLICAOF_b2c0a7e1"  # Redis 5.0+使用REPLICAOF
```

### 3.3 Systemd服务文件

```ini
# /etc/systemd/system/redis@.service
[Unit]
Description=Redis In-Memory Data Store (port %i)
After=network.target
Documentation=https://redis.io/documentation

[Service]
Type=notify
User=redis
Group=redis
Environment=REDISCLI_AUTH=${REDIS_PASSWORD}
ExecStart=/usr/local/redis/bin/redis-server /etc/redis/redis_%i.conf --supervised systemd
ExecStop=/usr/local/redis/bin/redis-cli -p %i shutdown
ExecReload=/bin/kill -USR2 $MAINPID
Restart=always
RestartSec=5
LimitNOFILE=655360
TimeoutStartSec=30
TimeoutStopSec=30

# 安全加固
NoNewPrivileges=yes
ProtectSystem=full
ProtectHome=yes
ReadWritePaths=/data/redis /var/log/redis /var/run/redis

[Install]
WantedBy=multi-user.target
```

### 3.4 创建集群

```bash
#!/bin/bash
# create_redis_cluster.sh - 创建Redis Cluster

set -euo pipefail

export REDISCLI_AUTH="${REDIS_PASSWORD}"

echo "========== 1. 启动所有Redis实例 =========="
for i in {11..16}; do
  for port in 6379; do  # 每台1个实例，共6节点
    echo "启动 10.10.40.${i}:${port}..."
    ssh root@10.10.40.${i} "systemctl start redis@${port}"
  done
done

echo "等待所有实例启动..."
sleep 5

echo "========== 2. 验证实例状态 =========="
for i in {11..16}; do
  for port in 6379; do  # 验证集群节点
    status=$(redis-cli -h 10.10.40.${i} -p ${port} ping 2>/dev/null)
    echo "  10.10.40.${i}:${port} -> ${status}"
    if [ "$status" != "PONG" ]; then
      echo "  ❌ Redis未正常响应"
      exit 1
    fi
  done
done

echo "========== 3. 创建集群(3主3从) =========="
# 创建6节点集群(3主3从)，--cluster-replicas 1 表示每个主节点有1个从节点
# 如果需要12实例(6主6从)，需列出所有12个实例地址
redis-cli --cluster create \
  10.10.40.11:6379 10.10.40.12:6379 10.10.40.13:6379 \
  10.10.40.14:6379 10.10.40.15:6379 10.10.40.16:6379 \
  --cluster-replicas 1

echo "========== 4. 验证集群状态 =========="
redis-cli cluster info
echo ""
echo "集群节点:"
redis-cli cluster nodes

echo "========== 5. 测试集群功能 =========="
echo "写入测试数据..."
for i in {1..100}; do
  redis-cli -c -h 10.10.40.11 -p 6379     SET "test:key:${i}" "value_${i}" > /dev/null 2>&1
done

echo "读取测试数据..."
redis-cli -c -h 10.10.40.14 -p 6379   GET "test:key:1" > /dev/null 2>&1 && echo "✅ 跨节点读写正常"

echo "✅ Redis Cluster创建完成"
```

---

> **⚠️ 架构边界说明**:
> - **Redis Cluster**: 分布式分片方案，自带主从切换和故障转移，适用于数据量大(>10GB)、需要水平扩展的场景
> - **Redis Sentinel**: 主从高可用方案，仅管理故障转移，适用于数据量小、单主够用的场景
> - **两者互斥**: 不建议在同一套数据上同时部署Cluster和Sentinel
> - **本项目选型**: 生产环境推荐Cluster(自带HA)；Sentinel作为备选方案单独展示

## 四、Sentinel哨兵部署（备选方案）

### 4.1 Sentinel配置

```ini
# /etc/redis/sentinel.conf - 3节点Sentinel
port 26379
daemonize yes
pidfile /var/run/redis/sentinel.pid
logfile /var/log/redis/sentinel.log
dir /data/redis

# 监控主节点
sentinel monitor mymaster 10.10.40.11 6379 2
sentinel auth-pass mymaster ${REDIS_PASSWORD}

# 下线判定
sentinel down-after-milliseconds mymaster 5000
sentinel failover-timeout mymaster 30000
sentinel parallel-syncs mymaster 1

# 通知脚本
sentinel notification-script mymaster /opt/scripts/redis-notify.sh
sentinel client-reconfig-script mymaster /opt/scripts/redis-reconfig.sh
```

### 4.2 Sentinel常用命令

```bash
# 查看Sentinel状态
redis-cli -p 26379 sentinel master mymaster
redis-cli -p 26379 sentinel slaves mymaster
redis-cli -p 26379 sentinel sentinels mymaster

# 手动故障切换(计划维护时使用)
redis-cli -p 26379 sentinel failover mymaster

# 重置Sentinel状态(故障恢复后)
redis-cli -p 26379 sentinel reset mymaster

# 检查Sentinel leader选举
redis-cli -p 26379 sentinel get-master-addr-by-name mymaster

# Sentinel故障切换流程:
# 1. subjective-down (SDOWN): 单个Sentinel认为Master不可达
# 2. objective-down (ODOWN): quorum个Sentinel都认为Master不可达
# 3. leader选举: Sentinel之间选举leader执行failover
# 4. 选择新Master: 优先级→offset→runid
# 5. 通知客户端: 更新拓扑信息
```

### 4.3 故障切换通知脚本

```bash
#!/bin/bash
# redis-notify.sh - Redis故障切换通知
# 参数: $1=<master|slave|failover|reconf> $2=name $3=old-state $4=new-state

EVENT=$1
NAME=$2
OLD_STATE=$3
NEW_STATE=$4

LOG_FILE="/var/log/redis/failover.log"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] EVENT=${EVENT} NAME=${NAME} OLD=${OLD_STATE} NEW=${NEW_STATE}" >> ${LOG_FILE}

# 钉钉通知
DINGTALK_TOKEN="your-dingtalk-webhook-token"
curl -s -X POST "https://oapi.dingtalk.com/robot/send?access_token=${DINGTALK_TOKEN}"   -H 'Content-Type: application/json'   -d "{
    "msgtype": "markdown",
    "markdown": {
      "title": "Redis故障切换",
      "text": "## Redis故障切换通知\n- **事件**: ${EVENT}\n- **实例**: ${NAME}\n- **旧状态**: ${OLD_STATE}\n- **新状态**: ${NEW_STATE}\n- **时间**: $(date '+%Y-%m-%d %H:%M:%S')"
    }
  }' 

# 如果是主从切换，发送紧急短信
if [ "${EVENT}" = "failover" ]; then
  echo "Redis主从切换发生！请立即检查！" | mail -s "CRITICAL: Redis Failover" ops@company.com
fi
```

---

## 五、内存优化深度指南

### 5.1 大Key扫描与清理

```bash
#!/bin/bash
# scan_big_keys.sh - 扫描大Key

set -euo pipefail

export REDISCLI_AUTH="${REDIS_PASSWORD}"

REDIS_CMD="redis-cli -h 10.10.40.11 -p 6379"

echo "========== 扫描大Key =========="
${REDIS_CMD} --bigkeys

echo ""
echo "========== 内存分析 =========="
${REDIS_CMD} memory usage test:key:1 SAMPLES 5

echo ""
echo "========== 内存统计 =========="
${REDIS_CMD} info memory | grep -E "used_memory_human|mem_fragmentation_ratio|mem_allocator"

echo ""
echo "========== 内存碎片率诊断 =========="
FRAG_RATIO=$(${REDIS_CMD} info memory | grep mem_fragmentation_ratio | cut -d: -f2 | tr -d '\r')
if (( $(echo "${FRAG_RATIO} > 1.5" | bc -l) )); then
  echo "⚠️ 碎片率过高 (${FRAG_RATIO})，建议执行 MEMORY PURGE"
  ${REDIS_CMD} memory purge
elif (( $(echo "${FRAG_RATIO} < 1.0" | bc -l) )); then
  echo "⚠️ 碎片率过低 (${FRAG_RATIO})，可能有swap，检查系统内存"
else
  echo "✅ 碎片率正常 (${FRAG_RATIO})"
fi
```

### 5.2 内存优化最佳实践

| 优化项 | 方法 | 效果 |
|--------|------|------|
| 数据结构选择 | 小数据用ziplist/listpack | 内存节省30-50% |
| 编码优化 | hash-max-ziplist-entries 512 | 小hash省内存 |
| 压缩列表 | zset-max-ziplist-entries 128 | 小zset省内存 |
| 整数集合 | set-max-intset-entries 512 | 小set省内存 |
| 过期策略 | 业务key必须设置TTL | 防止内存泄漏 |
| 淘汰策略 | allkeys-lru 或 volatile-lru | 智能淘汰 |
| 序列化 | 避免JDK序列化，用Protobuf/MsgPack | 节省50%+ |
| 大Key拆分 | Hash>5000字段拆分 | 避免阻塞 |
| 惰性删除 | lazyfree-lazy-expire yes | 减少阻塞 |

### 5.3 内存泄漏排查

```bash
export REDISCLI_AUTH="${REDIS_PASSWORD}"

# 1. 监控内存增长趋势
redis-cli -h 10.10.40.11 -p 6379   INFO memory | grep used_memory_human

# 2. 分析key数量变化
redis-cli -h 10.10.40.11 -p 6379   INFO keyspace

# 3. 抓取内存分配器信息
redis-cli -h 10.10.40.11 -p 6379   MEMORY MALLOC-STATS

# 4. 使用memory doctor诊断
redis-cli -h 10.10.40.11 -p 6379   MEMORY DOCTOR
```

---

## 六、持久化策略深度对比

### 6.1 RDB vs AOF vs 混合

| 特性 | RDB | AOF | 混合(推荐) |
|------|-----|-----|-----------|
| 持久化方式 | 快照 | 追加日志 | RDB+日志 |
| 数据安全性 | 可能丢失几分钟 | 最多丢1秒 | 最多丢1秒 |
| 恢复速度 | 快(二进制加载) | 慢(重放日志) | 快(RDB+增量) |
| 文件大小 | 小(压缩) | 大(文本) | 中等 |
| 性能影响 | fork时有短暂阻塞 | 每秒fsync | 每秒fsync |
| 推荐场景 | 备份 | 数据安全 | 生产环境 |

### 6.2 生产环境推荐配置

```ini
# RDB: 用于快速恢复和备份
save 900 1        # 15分钟内至少1次修改
save 300 10       # 5分钟内至少10次修改
save 60 10000     # 1分钟内至少10000次修改

# AOF: 用于数据安全
appendonly yes
appendfsync everysec   # 每秒同步，平衡性能和安全
no-appendfsync-on-rewrite yes  # rewrite时不fsync

# 混合持久化(Redis 4.0+)
aof-use-rdb-preamble yes  # AOF文件包含RDB头+增量AOF
```

---

## 七、性能调优参数

### 7.1 关键参数详解

```ini
# ===== 网络层调优 =====
tcp-backlog 511            # TCP连接队列，高并发时增大
tcp-keepalive 300          # 保活探测间隔
timeout 300                # 空闲连接超时

# ===== 应用层调优 =====
io-threads 2               # IO线程数(8C服务器建议2，不宜超过核心数一半)
io-threads-do-reads yes    # 读操作使用多线程
lazyfree-lazy-eviction yes # 异步淘汰，减少阻塞
lazyfree-lazy-expire yes   # 异步过期，减少阻塞

# ===== 内存层调优 =====
maxmemory 10gb
maxmemory-policy allkeys-lru   # 缓存场景推荐allkeys-lru(所有key均可淘汰，防止OOM)
maxmemory-samples 10           # LRU采样数，越大越精确

# ===== 持久化调优 =====
auto-aof-rewrite-percentage 100
auto-aof-rewrite-min-size 64mb
```

### 7.2 性能基准测试

```bash
export REDISCLI_AUTH="${REDIS_PASSWORD}"

# 使用redis-benchmark测试
redis-benchmark -h 10.10.40.11 -p 6379   -c 100 -n 1000000 -t set,get -q

# 预期结果:
# SET: 150,000+ ops/sec (单节点)
# GET: 200,000+ ops/sec (单节点)
# 6节点集群总QPS: 1,000,000+
```

---

## 八、真实故障案例与解决方案

### 案例1: Redis Cluster Slot迁移超时

**故障现象**: 业务大量超时，Redis Cluster日志报 `CLUSTERDOWN` 错误

**根因分析**:
- 执行 `redis-cli --cluster rebalance` 迁移slot时
- 某个slot数据量过大(单个key 100MB)
- 迁移过程中目标节点内存不足
- 导致slot迁移卡住，集群状态变为 `FAIL`

**解决方案**:
```bash
export REDISCLI_AUTH="${REDIS_PASSWORD}"

# 1. 查看集群状态
redis-cli -c -h 10.10.40.11 cluster info | grep cluster_state

# 2. 手动完成迁移
redis-cli -c -h 10.10.40.11   CLUSTER SETSLOT <slot> NODE <target-node-id>

# 3. 设置集群允许降级读取
redis-cli -c -h 10.10.40.11   CONFIG SET cluster-allow-reads-when-down yes
```

**预防措施**:
- 迁移前检查每个slot的数据量
- 设置 `cluster-allow-reads-when-down yes` 允许降级读取
- 避免在业务高峰期迁移slot

### 案例2: Redis内存爆炸导致OOM

**故障现象**: Redis实例被OOM Killer杀死，业务完全不可用

**根因分析**:
```bash
export REDISCLI_AUTH="${REDIS_PASSWORD}"

# 发现大量未设置TTL的key
redis-cli -c -h 10.10.40.11 INFO keyspace
# db0:keys=5000000,expires=100000  # 只有2%的key设置了过期时间

# 内存使用
redis-cli -c -h 10.10.40.11 INFO memory
# used_memory_human:19.8G  # 接近20GB上限
```

**解决方案**:
```bash
export REDISCLI_AUTH="${REDIS_PASSWORD}"

# 1. 紧急清理大Key
redis-cli -c -h 10.10.40.11 --bigkeys

# 2. 批量设置TTL(使用Lua脚本保证原子性)
redis-cli -c -h 10.10.40.11 --eval "
  local cursor = 0
  repeat
    local result = redis.call('SCAN', cursor, 'COUNT', 1000)
    cursor = tonumber(result[1])
    local keys = result[2]
    for _, key in ipairs(keys) do
      local ttl = redis.call('TTL', key)
      if ttl == -1 then
        redis.call('EXPIRE', key, 86400)
      end
    end
  until cursor == 0
" , 0

# 3. 调整淘汰策略
redis-cli -c -h 10.10.40.11   CONFIG SET maxmemory-policy allkeys-lru

# 4. 设置告警阈值
# Prometheus告警规则
- alert: RedisHighMemory
  expr: redis_memory_used_bytes / redis_memory_max_bytes > 0.85
  for: 5m
  labels:
    severity: warning
```

**预防措施**:
- 所有业务key必须设置TTL
- 部署Redis内存监控告警(85%阈值)
- 使用 `allkeys-lru` 淘汰策略
- 定期执行 `--bigkeys` 扫描

### 案例3: Redis Cluster网络分区导致脑裂

**故障现象**: 出现两个master同时接受写入，数据不一致

**根因分析**:
- 网络分区导致部分节点无法通信
- `cluster-node-timeout` 设置过短(5秒)
- Cluster内部gossip协议误判主节点下线，触发failover
- 旧master恢复后，出现双主

**解决方案**:
```bash
export REDISCLI_AUTH="${REDIS_PASSWORD}"

# 1. 调整cluster-node-timeout
redis-cli -c -h 10.10.40.11   CONFIG SET cluster-node-timeout 15000

# 2. 检查集群状态
redis-cli -c -h 10.10.40.11 cluster nodes | grep FAIL

# 3. 手动修复slot分配
redis-cli -c -h 10.10.40.11   CLUSTER SETSLOT <slot> STABLE
```

**预防措施**:
- `cluster-node-timeout` 建议15秒以上
- 启用 `cluster-require-full-coverage no  # 允许部分slot不可用时继续服务`
- 部署跨机架/跨可用区的节点

### 案例4: 慢查询阻塞Redis

**故障现象**: Redis响应时间从1ms飙升到500ms，业务超时率飙升

**根因分析**:
```bash
export REDISCLI_AUTH="${REDIS_PASSWORD}"

# 查看慢查询日志
redis-cli -c -h 10.10.40.11 slowlog get 50

# 发现大量 KEYS 命令(已禁用但仍有)
# 发现大量 SORT 命令(对大集合排序)
# 发现 SCAN 命令在大key上执行
```

**解决方案**:
```bash
# 1. 禁用危险命令(已在配置中)
rename-command KEYS "KEYS_b2c0a7e1"

# 2. 优化业务代码
# - 避免使用KEYS命令，改用SCAN
# - 避免对大集合SORT，使用索引
# - 大key操作拆分为小批量

# 3. 设置慢查询告警
- alert: RedisSlowQueries
  expr: rate(redis_slowlog_length[5m]) > 0
  for: 5m
  labels:
    severity: warning
```

---

## 九、灾备方案与切换演练

### 9.1 备份策略

```bash
#!/bin/bash
# redis_backup.sh - Redis自动备份

set -euo pipefail

export REDISCLI_AUTH="${REDIS_PASSWORD}"

BACKUP_DIR="/data/backup/redis"
DATE=$(date +%Y%m%d_%H%M%S)
KEEP_DAYS=7

mkdir -p ${BACKUP_DIR}

echo "========== RDB备份 =========="
for node in 10.10.40.{11..16}; do
  for port in 6379; do  # 每台1个Redis实例(Cluster模式)
    BEFORE=$(redis-cli -h ${node} -p ${port} LASTSAVE)
    redis-cli -h ${node} -p ${port} BGSAVE
    
    # 等待备份完成(LASTSAVE时间戳变化)
    while [ "$(redis-cli -h ${node} -p ${port} LASTSAVE)" = "$BEFORE" ]; do
      sleep 1
    done
    # 复制RDB文件
    # 使用cp避免与BGSAVE竞态，确保文件一致性
    ssh root@${node} "cp /data/redis/dump_${port}.rdb ${BACKUP_DIR}/dump_${node}_${port}_${DATE}.rdb"
    # 验证RDB文件magic number
    echo "  ✅ ${node}:${port} 备份完成"
  done
done
echo "========== 清理过期备份 =========="
find ${BACKUP_DIR} -name "*.rdb" -mtime +${KEEP_DAYS} -delete

echo "========== 备份验证 =========="
ls -lh ${BACKUP_DIR}/*${DATE}*.rdb

# 验证RDB文件magic number
for rdb_file in ${BACKUP_DIR}/*${DATE}*.rdb; do
  if file ${rdb_file} | grep -q "Redis RDB"; then
    echo "  ✅ $(basename ${rdb_file}) RDB文件完整性验证通过"
  else
    echo "  ❌ $(basename ${rdb_file}) RDB文件损坏"
    exit 1
  fi
done

echo "✅ 备份完成"
```

### 9.2 恢复流程

```bash
#!/bin/bash
# redis_restore.sh - Redis数据恢复

set -euo pipefail

export REDISCLI_AUTH="${REDIS_PASSWORD}"

echo "⚠️ 警告: 此操作将覆盖当前数据！"
echo "请确认恢复目标: "
echo "1. 单节点恢复"
echo "2. 整集群恢复"
read -p "选择 (1/2): " CHOICE

if [ "${CHOICE}" = "1" ]; then
  read -p "目标节点IP: " TARGET_IP
  read -p "目标端口: " TARGET_PORT
  read -p "RDB文件路径: " RDB_PATH
  
  echo "停止Redis..."
  ssh root@${TARGET_IP} "systemctl stop redis@${TARGET_PORT}"
  
  echo "复制RDB文件..."
  scp ${RDB_PATH} root@${TARGET_IP}:/data/redis/dump_${TARGET_PORT}.rdb
  ssh root@${TARGET_IP} "chown redis:redis /data/redis/dump_${TARGET_PORT}.rdb"
  
  echo "启动Redis..."
  ssh root@${TARGET_IP} "systemctl start redis@${TARGET_PORT}"
  
  echo "验证数据..."
  redis-cli -h ${TARGET_IP} -p ${TARGET_PORT} DBSIZE
  
  echo "✅ 恢复完成"
fi
```

### 9.3 灾备切换演练

```bash
#!/bin/bash
# failover_drill.sh - 故障转移演练

set -euo pipefail

export REDISCLI_AUTH="${REDIS_PASSWORD}"

echo "============================================"
echo "  Redis Cluster故障转移演练"
echo "============================================"

echo "演练前状态:"
redis-cli -c -h 10.10.40.11 cluster nodes | grep master

echo ""
echo "Step 1: 模拟Master-01故障(停止Redis)..."
ssh root@10.10.40.11 "systemctl stop redis@6379"

echo "Step 2: 等待故障转移(最多30秒)..."
for i in {1..30}; do
  STATE=$(redis-cli -c -h 10.10.40.12 cluster info 2>/dev/null | grep cluster_state)
  echo "  ${i}s: ${STATE}"
  if echo "${STATE}" | grep -q "ok"; then
    echo "✅ 故障转移成功！"
    break
  fi
  sleep 1
done

echo "Step 3: 验证新Master..."
redis-cli -c -h 10.10.40.12 cluster nodes | grep master

echo "Step 4: 恢复旧Master为从节点..."
ssh root@10.10.40.11 "systemctl start redis@6379"

echo "Step 5: 重新加入集群..."
redis-cli -c -h 10.10.40.11 CLUSTER REPLICATE <new-master-id>

echo ""
echo "演练结果:"
echo "  - RTO(恢复时间): < 30秒"
echo "  - RPO(数据丢失): < 1秒(AOF everysec)"
echo "  - 业务影响: 无感知"
```

---

## 十、容量规划

### 10.1 内存估算公式

```
所需内存 = 业务数据量 × 1.5(碎片系数) × 1.2(安全余量)

示例:
- 业务数据量: 30GB
- 所需内存: 30 × 1.5 × 1.2 = 54GB
- 单机内存: 20GB
- 最少节点数: ceil(54 / 20) × 2(主从) = 6节点
```

### 10.2 QPS估算

```
单节点QPS ≈ 10-15万(取决于硬件和数据结构复杂度)

示例:
- 单节点QPS: 10万
- 业务峰值QPS: 30万
- 最少主节点数: ceil(30万 / 10万) = 3主
- 加从节点: 5 × 2 = 10节点
```

### 10.3 连接数规划

```
最大连接数 = 应用实例数 × 每实例连接池大小 × 1.5(安全余量)

示例:
- 应用实例: 50个
- 每实例连接池: 100
- 最大连接数: 50 × 100 × 1.5 = 7500
- 单节点maxclients: 10000 ✓
```

---

## 十、Redis Cluster扩缩容方案

### 10.1 添加节点(扩容)

```bash
# 1. 启动新节点(例如10.10.40.17:6379)
ssh root@10.10.40.17 "systemctl start redis@6379"

# 2. 将新节点加入集群
redis-cli --cluster add-node 10.10.40.17:6379 10.10.40.11:6379

# 3. 分配slot(从现有节点迁移slot到新节点)
redis-cli --cluster reshard 10.10.40.11:6379 \
  --cluster-from <source-node-id> \
  --cluster-to <new-node-id> \
  --cluster-slots 4096 \
  --cluster-yes

# 4. 验证
redis-cli --cluster check 10.10.40.11:6379
```

### 10.2 移除节点(缩容)

```bash
# 1. 迁移该节点的slot到其他节点
redis-cli --cluster reshard 10.10.40.11:6379 \
  --cluster-from <node-to-remove-id> \
  --cluster-to <target-node-id> \
  --cluster-slots <slot-count> \
  --cluster-yes

# 2. 移除节点(如果是从节点)
redis-cli --cluster del-node 10.10.40.11:6379 <node-to-remove-id>

# 3. 关闭并下线节点
ssh root@10.10.40.17 "systemctl stop redis@6379"
```

### 10.3 Slot分配规划

| 节点 | Slot范围 | 负责数据 |
|------|----------|----------|
| Node-01 | 0-5460 | 约1/3数据 |
| Node-02 | 5461-10922 | 约1/3数据 |
| Node-03 | 10923-16383 | 约1/3数据 |

---

## 十一、Sentinel迁移到Cluster方案

### 11.1 迁移前提

```bash
# Sentinel和Cluster可以并行运行(Redis 7.0+)
# Sentinel和Cluster是两套独立的高可用方案，不建议混用
# 推荐: 根据场景二选一。Cluster适合大数据量分片，Sentinel适合小规模简单HA
# 如果需要从Sentinel迁移到Cluster，应先完成迁移再下线Sentinel
```

### 11.2 迁移步骤

```bash
# 1. 在Cluster中导入Sentinel数据
# Redis Cluster不支持SELECT，需要逐key迁移
redis-cli --cluster import 10.10.40.11:6379 \
  --cluster-from 10.10.40.11:6379 \
  --cluster-copy \
  --cluster-replace

# 2. 验证数据一致性
redis-cli -h 10.10.40.11 -p 6379 dbsize

# 3. 更新应用连接地址
# Sentinel: host:port → Cluster: host1:port1,host2:port2,...
# 使用redis-cli --cluster check验证所有节点健康
```

---

## 十二、客户端连接池配置

### 12.1 Java (Jedis/Lettuce)

```java
// Jedis连接池配置
JedisPoolConfig poolConfig = new JedisPoolConfig();
poolConfig.setMaxTotal(128);          // 最大连接数
poolConfig.setMaxIdle(64);            // 最大空闲连接
poolConfig.setMinIdle(16);            // 最小空闲连接
poolConfig.setMaxWaitMillis(3000);    // 获取连接超时
poolConfig.setTestOnBorrow(true);     // 借出时检测连接
poolConfig.setTestWhileIdle(true);    // 空闲时检测连接

// Cluster模式连接
Set<HostAndPort> nodes = new HashSet<>();
nodes.add(new HostAndPort("10.10.40.11", 6379));
nodes.add(new HostAndPort("10.10.40.12", 6379));
nodes.add(new HostAndPort("10.10.40.13", 6379));
JedisCluster cluster = new JedisCluster(nodes, 3000, 3000, 3, "password", poolConfig);
```

```java
// Lettuce连接池(Spring Boot)
spring:
  redis:
    cluster:
      nodes: 10.10.40.11:6379,10.10.40.12:6379,10.10.40.13:6379
    lettuce:
      pool:
        max-active: 128
        max-idle: 64
        min-idle: 16
        max-wait: 3000ms
```

### 12.2 Go (go-redis)

```go
rdb := redis.NewClusterClient(&redis.ClusterOptions{
    Addrs:        []string{"10.10.40.11:6379", "10.10.40.12:6379", "10.10.40.13:6379"},
    Password:     "your-password",
    PoolSize:     128,           // 连接池大小
    MinIdleConns: 16,            // 最小空闲连接
    PoolTimeout:  3 * time.Second,
    ReadTimeout:  3 * time.Second,
    WriteTimeout: 3 * time.Second,
    RouteByLatency: true,        // 按延迟路由(集群模式)
})
```

### 12.3 连接池参数建议

| 参数 | 开发环境 | 生产环境(8C/32G) | 说明 |
|------|----------|-------------------|------|
| maxTotal | 20 | 128 | 最大连接数 |
| maxIdle | 10 | 64 | 最大空闲连接 |
| minIdle | 5 | 16 | 最小空闲连接(保持预热) |
| maxWait | 3s | 3s | 获取连接超时 |
| testOnBorrow | true | true | 借出时检测连接活性 |
| testWhileIdle | true | true | 空闲时定期检测 |

---

## 十三、运维SOP

### 13.1 日常巡检

```bash
#!/bin/bash
# daily_check.sh - Redis日常巡检

set -euo pipefail

export REDISCLI_AUTH="${REDIS_PASSWORD}"

echo "========== Redis集群日常巡检 $(date '+%Y-%m-%d %H:%M') =========="

for node in 10.10.40.{11..16}; do
  for port in 6379; do
    echo ""
    echo "--- ${node}:${port} ---"
    
    # 1. 实例状态
    PING=$(redis-cli -h ${node} -p ${port} ping 2>/dev/null)
    echo "  状态: ${PING}"
    if [ "$PING" != "PONG" ]; then
      echo "  ❌ Redis未正常响应"
      exit 1
    fi
    
    # 2. 内存使用
    MEM=$(redis-cli -h ${node} -p ${port} INFO memory 2>/dev/null | grep used_memory_human | cut -d: -f2 | tr -d '\r')
    echo "  内存: ${MEM}"
    
    # 3. 连接数
    CONN=$(redis-cli -h ${node} -p ${port} INFO clients 2>/dev/null | grep connected_clients | cut -d: -f2 | tr -d '\r')
    echo "  连接数: ${CONN}"
    
    # 4. 命中率
    HITS=$(redis-cli -h ${node} -p ${port} INFO stats 2>/dev/null | grep keyspace_hits | cut -d: -f2 | tr -d '\r')
    MISSES=$(redis-cli -h ${node} -p ${port} INFO stats 2>/dev/null | grep keyspace_misses | cut -d: -f2 | tr -d '\r')
    if [ "${HITS}" -gt 0 ] 2>/dev/null; then
      HIT_RATE=$(echo "scale=2; ${HITS} / (${HITS} + ${MISSES}) * 100" | bc 2>/dev/null || echo "N/A")
      echo "  命中率: ${HIT_RATE}%"
    fi
    
    # 5. 碎片率
    FRAG=$(redis-cli -h ${node} -p ${port} INFO memory 2>/dev/null | grep mem_fragmentation_ratio | cut -d: -f2 | tr -d '\r')
    echo "  碎片率: ${FRAG}"
    
    # 6. 慢查询数量
    SLOW=$(redis-cli -h ${node} -p ${port} SLOWLOG LEN 2>/dev/null)
    echo "  慢查询: ${SLOW}条"
  done
done

echo ""
echo "========== 集群状态 =========="
redis-cli -c -h 10.10.40.11 cluster info 2>/dev/null | grep -E "cluster_state|cluster_slots|cluster_known_nodes"
```

### 13.2 周度维护

```bash
#!/bin/bash
# weekly_maintenance.sh - Redis周度维护

set -euo pipefail

export REDISCLI_AUTH="${REDIS_PASSWORD}"

echo "========== Redis周度维护 $(date '+%Y-%m-%d') =========="

echo "1. 大Key扫描..."
for node in 10.10.40.{11..16}; do
  redis-cli -h ${node} -p 6379 --bigkeys > /tmp/bigkeys_${node}.log 2>/dev/null
  BIG_KEYS=$(grep -c "Biggest" /tmp/bigkeys_${node}.log 2>/dev/null || echo "0")
  echo "  ${node}: ${BIG_KEYS}个大Key"
done

echo "2. 内存碎片整理..."
for node in 10.10.40.{11..16}; do
  redis-cli -h ${node} -p 6379 MEMORY PURGE > /dev/null 2>&1
  echo "  ${node}: 碎片整理完成"
done

echo "3. 慢查询日志清理..."
for node in 10.10.40.{11..16}; do
  redis-cli -h ${node} -p 6379 SLOWLOG RESET > /dev/null 2>&1
  echo "  ${node}: 慢查询日志已清理"
done

echo "4. 备份验证..."
# 验证最近的备份文件
LATEST_BACKUP=$(ls -t /data/backup/redis/*.rdb 2>/dev/null | head -1)
if [ -n "${LATEST_BACKUP}" ]; then
  echo "  最新备份: ${LATEST_BACKUP}"
  ls -lh ${LATEST_BACKUP}
fi

echo "✅ 周度维护完成"
```

---

## 十四、应急预案

### 14.1 Redis不可用

```
1. 立即检查:
   - 所有Redis实例是否存活
   - 网络连通性
   - 磁盘空间

2. 紧急处理:
   - 如果是单节点故障，等待自动failover
   - 如果是网络问题，检查交换机/防火墙
   - 如果是OOM，立即清理大Key

3. 恢复后:
   - 检查数据一致性
   - 监控业务恢复情况
   - 记录故障报告
```

### 14.2 数据丢失

```
1. 立即停止写入
2. 从最近的备份恢复
3. 使用AOF回放到故障前
4. 验证数据完整性
5. 通知业务方
```

---

## 十五、监控告警

```yaml
# prometheus-redis-alerts.yaml
groups:
  - name: redis-alerts
    rules:
      - alert: RedisDown
        expr: redis_up == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "Redis宕机: {{ $labels.instance }}"
      
      - alert: RedisHighMemory
        expr: redis_memory_used_bytes / redis_memory_max_bytes > 0.85
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Redis内存使用率>85%: {{ $labels.instance }}"
          description: "当前: {{ $value | humanizePercentage }}"
      
      - alert: RedisClusterState
        expr: redis_cluster_state != 1
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "Redis Cluster状态异常"
      
      - alert: RedisHighLatency
        expr: histogram_quantile(0.99, rate(redis_commands_duration_seconds_bucket[5m])) > 0.01
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Redis P99延迟>10ms"
      
      - alert: RedisLowHitRate
        expr: |
          redis_keyspace_hits_total / (redis_keyspace_hits_total + redis_keyspace_misses_total) * 100 < 80
        for: 15m
        labels:
          severity: warning
        annotations:
          summary: "Redis缓存命中率<80%"
```

---

## 十六、项目文件清单

```
redis-cluster/
├── scripts/
├── configs/                 # 配置文件(gitlab-ci/Dockerfile/Helm/Terraform/Ansible)
├── tests/                  # 部署验证测试
│   ├── init_redis_nodes.sh          # 节点初始化
│   ├── create_redis_cluster.sh      # 创建集群
│   ├── redis_backup.sh              # 备份脚本
│   ├── redis_restore.sh             # 恢复脚本
│   ├── failover_drill.sh            # 故障转移演练
│   ├── daily_check.sh               # 日常巡检
│   ├── weekly_maintenance.sh        # 周度维护
│   ├── scan_big_keys.sh             # 大Key扫描
│   └── redis-notify.sh              # 故障通知
├── conf/
│   ├── redis_cluster.conf           # Cluster配置模板
│   ├── sentinel.conf                # Sentinel配置
│   └── redis@.service               # Systemd服务
├── k8s/
│   ├── prometheus-redis-alerts.yaml # 告警规则
│   └── redis-exporter.yaml          # Exporter部署
└── README.md
```

---

## 十七、关键要点总结

### 17.1 架构要点
- **Cluster**: 6节点起步，3主3从，16384个slot均匀分配
- **Sentinel**: 3节点，quorum=2，自动故障转移
- **持久化**: 混合模式(RDB+AOF)，everysec同步
- **内存**: maxmemory + allkeys-lru，预留15%余量

### 17.2 性能要点
- **网络**: tcp-backlog 511, tcp-keepalive 300
- **IO**: io-threads 2, io-threads-do-reads yes
- **内存**: lazyfree异步删除, maxmemory-samples 10
- **持久化**: aof-use-rdb-preamble yes

### 17.3 安全要点
- **认证**: requirepass + masterauth
- **命令禁用**: KEYS, FLUSHALL, CONFIG, SHUTDOWN
- **网络**: 绑定内网IP, 防火墙限制
- **审计**: 慢查询日志, 命令统计

### 17.4 监控要点
- **核心指标**: 内存、连接数、命中率、QPS、延迟
- **告警阈值**: 内存85%、延迟10ms、命中率80%
- **集群状态**: cluster_state、slot分配、节点状态
- **备份状态**: RDB文件大小、备份时间、恢复测试

---



## 踩坑记录

### Q1: Redis Cluster创建时报"Node is not empty"
**原因**: 目标节点已有数据
**解决**: 先执行FLUSHALL清空数据，再创建集群

### Q2: Cluster节点间通信超时
**原因**: 节点间网络延迟过高
**解决**: 增大cluster-node-timeout到15000ms

### Q3: 某个slot无法写入
**原因**: 该slot对应的master节点故障且无slave接管
**解决**: 检查cluster slots，修复故障节点

### Q4: 内存碎片率过高(>1.5)
**原因**: 大量key删除后内存未回收
**解决**: 配置activedefrag yes或重启Redis

### Q5: Sentinel切换后客户端连接失败
**原因**: 客户端缓存了旧的master地址
**解决**: 客户端配置Sentinel发现机制，不硬编码IP

> 本项目基于官方文档、技术博客和社区实践深度学习编写
> 包含真实故障案例、性能调优参数、灾备方案、容量规划、运维SOP
> 适用于: 电商、社交、游戏等高并发Redis场景