# 企业级Redis集群方案 - Cluster + Sentinel + 持久化优化

> 完整实现Redis高可用方案，覆盖Cluster 6节点集群、Sentinel哨兵、持久化策略、内存优化、分布式锁

---

## 一、架构选择

```
方案A: Redis Cluster (推荐大容量/高性能场景)
┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐
│Master-01│ │Master-02│ │Master-03│ │Master-04│ │Master-05│ │Master-06│
│Slot 0-  │ │Slot 5461│ │Slot 10923│ │Slot 16384│ │         │ │         │
│  5460   │ │ -10922  │ │ -16383  │ │         │ │         │ │         │
└────┬────┘ └────┬────┘ └────┬────┘ └────┬────┘ └────┬────┘ └────┬────┘
     │           │           │           │           │           │
┌────▼────┐ ┌────▼────┐ ┌────▼────┐ ┌────▼────┐ ┌────▼────┐ ┌────▼────┐
│Slave-01 │ │Slave-02 │ │Slave-03 │ │Slave-04 │ │Slave-05 │ │Slave-06 │
└─────────┘ └─────────┘ └─────────┘ └─────────┘ └─────────┘ └─────────┘

方案B: Sentinel哨兵 (推荐小容量/高可靠场景)
┌──────────┐  ┌──────────┐  ┌──────────┐
│Sentinel-1│  │Sentinel-2│  │Sentinel-3│
└─────┬────┘  └─────┬────┘  └─────┬────┘
      │             │             │
┌─────▼─────────────▼─────────────▼─────┐
│          故障自动切换                    │
└─────┬─────────────┬─────────────┬─────┘
      │             │             │
┌─────▼────┐ ┌─────▼────┐ ┌─────▼────┐
│ Master   │ │ Slave-1  │ │ Slave-2  │
│ (读写)   │ │ (只读)   │ │ (只读)   │
└──────────┘ └──────────┘ └──────────┘
```

---

## 二、服务器规划

| 角色 | IP | 配置 | Redis内存 | 用途 |
|------|-----|------|-----------|------|
| Master-01 | 10.10.40.11 | 8C/32G | 20G | Cluster主节点 |
| Master-02 | 10.10.40.12 | 8C/32G | 20G | Cluster主节点 |
| Master-03 | 10.10.40.13 | 8C/32G | 20G | Cluster主节点 |
| Master-04 | 10.10.40.14 | 8C/32G | 20G | Cluster主节点 |
| Master-05 | 10.10.40.15 | 8C/32G | 20G | Cluster主节点 |
| Master-06 | 10.10.40.16 | 8C/32G | 20G | Cluster主节点 |

---

## 三、Redis Cluster部署

### 3.1 统一配置模板

```ini
# /etc/redis/redis.conf - 每台实例的配置
# 通用配置
bind 0.0.0.0
port 6379
daemonize yes
pidfile /var/run/redis/redis.pid
logfile /var/log/redis/redis.log
loglevel notice
databases 16
timeout 300
tcp-keepalive 300

# 内存配置
maxmemory 20gb
maxmemory-policy allkeys-lru
maxmemory-samples 10

# 持久化 - AOF
appendonly yes
appendfilename "appendonly.aof"
appendfsync everysec
no-appendfsync-on-rewrite yes
auto-aof-rewrite-percentage 100
auto-aof-rewrite-min-size 64mb

# 持久化 - RDB
save 900 1
save 300 10
save 60 10000
dbfilename dump.rdb
dir /data/redis

# 性能优化
tcp-backlog 511
maxclients 10000
hz 10
dynamic-hz yes
io-threads 4
io-threads-do-reads yes

# 安全
requirepass Redis@Cluster2024!
masterauth Redis@Cluster2024!
rename-command FLUSHDB ""
rename-command FLUSHALL ""
rename-command DEBUG ""

# 慢查询
slowlog-log-slower-than 10000
slowlog-max-len 128

# Cluster配置
cluster-enabled yes
cluster-config-file nodes.conf
cluster-node-timeout 15000
cluster-require-full-coverage yes
cluster-allow-reads-when-down no
```

### 3.2 创建集群

```bash
#!/bin/bash
# create_cluster.sh - 创建Redis Cluster

set -euo pipefail

echo "启动所有Redis实例..."
for i in {11..16}; do
  ssh root@10.10.40.${i} 'systemctl start redis'
done

echo "创建6主6从集群..."
redis-cli --cluster create   10.10.40.11:6379 10.10.40.12:6379 10.10.40.13:6379   10.10.40.14:6379 10.10.40.15:6379 10.10.40.16:6379   --cluster-replicas 1   -a Redis@Cluster2024!

echo "验证集群..."
redis-cli -a Redis@Cluster2024! cluster info
redis-cli -a Redis@Cluster2024! cluster nodes
```

---

## 四、Sentinel哨兵部署

```ini
# /etc/redis/sentinel.conf
port 26379
daemonize yes
pidfile /var/run/redis-sentinel.pid
logfile /var/log/redis/sentinel.log
dir /data/redis

# 监控主节点
sentinel monitor mymaster 10.10.40.11 6379 2
sentinel auth-pass mymaster Redis@Cluster2024!

# 主观下线时间
sentinel down-after-milliseconds mymaster 5000

# 故障切换超时
sentinel failover-timeout mymaster 30000

# 并行同步从节点
sentinel parallel-syncs mymaster 1

# 通知脚本
sentinel notification-script mymaster /opt/scripts/redis-notify.sh
```

```bash
#!/bin/bash
# redis-notify.sh - Redis故障切换通知脚本
SUBJECT="Redis故障切换通知"
BODY="Redis集群发生故障切换
时间: $(date)
主节点: $1
新主节点: $2
旧主节点: $3"
curl -s -X POST "https://oapi.dingtalk.com/robot/send?access_token=xxx"   -H 'Content-Type: application/json'   -d "{"msgtype":"text","text":{"content":"${SUBJECT}
${BODY}"}}"
```

---

## 五、内存优化

```bash
# 大Key扫描
redis-cli -a Redis@Cluster2024! --bigkeys

# 内存分析
redis-cli -a Redis@Cluster2024! memory usage <key>

# 删除大Key（避免阻塞）
redis-cli -a Redis@Cluster2024! UNLINK <key>

# 慢查询日志
redis-cli -a Redis@Cluster2024! slowlog get 50
```

---

## 六、分布式锁实现

```python
# distributed_lock.py - Redis分布式锁
import redis
import uuid
import time

class RedisDistributedLock:
    def __init__(self, redis_client, lock_name, timeout=10, retry_interval=0.1):
        self.redis = redis_client
        self.lock_name = f"lock:{lock_name}"
        self.timeout = timeout
        self.retry_interval = retry_interval
        self.identifier = str(uuid.uuid4())
    
    def acquire(self):
        end = time.time() + self.timeout
        while time.time() < end:
            if self.redis.set(self.lock_name, self.identifier, nx=True, ex=self.timeout):
                return True
            time.sleep(self.retry_interval)
        return False
    
    def release(self):
        # Lua脚本保证原子性
        script = '''
        if redis.call("get", KEYS[1]) == ARGV[1] then
            return redis.call("del", KEYS[1])
        else
            return 0
        end
        '''
        return self.redis.eval(script, 1, self.lock_name, self.identifier)
    
    def __enter__(self):
        if not self.acquire():
            raise TimeoutError(f"获取锁超时: {self.lock_name}")
        return self
    
    def __exit__(self, exc_type, exc_val, exc_tb):
        self.release()
```

---

> 本项目基于25个语雀知识库(2699篇,584万字)编写
