# 容量规划模型

## 业务增长预测
- 用户增长率: 预计月增长10-20%
- 数据增长率: 预计月增长15-25%
- 请求增长率: 预计月增长20-30%

## 资源使用率基线
| 组件 | CPU基线 | 内存基线 | 存储基线 | 扩容阈值 |
|------|---------|----------|----------|----------|
| K8s Master | 30% | 60% | 20% | CPU>70%或内存>80% |
| K8s Worker | 40% | 70% | 30% | CPU>75%或内存>85% |
| MySQL | 50% | 75% | 40% | CPU>70%或连接数>80% |
| Redis | 30% | 60% | 25% | 内存>75%或QPS>80% |
| ES | 40% | 80% | 50% | 磁盘>80%或JVM>75% |
| Prometheus | 25% | 50% | 35% | 磁盘>70% |

## 扩容触发条件
- CPU > 70% 持续5分钟
- 内存 > 80% 持续5分钟
- 磁盘 > 80%
- 连接数 > 80% 最大值
- QPS > 80% 峰值容量

## 存储增长曲线
| 组件 | 日增长 | 月增长 | 年增长 | 保留策略 |
|------|--------|--------|--------|----------|
| MySQL binlog | 5GB | 150GB | 1.8TB | 7天 |
| Redis RDB | 2GB | 60GB | 720GB | 7天 |
| ES日志 | 10GB | 300GB | 3.6TB | 30天热+90天冷 |
| Prometheus | 1GB | 30GB | 360GB | 30天 |
| Harbor镜像 | 5GB | 150GB | 1.8TB | 按标签保留 |

## 自动化容量检查脚本

```bash
#!/bin/bash
# capacity-check.sh - 自动化容量巡检
set -euo pipefail

echo "========== 容量巡检报告 =========="
echo "时间: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

# 1. K8s节点资源使用率
echo ">>> K8s节点资源:"
kubectl top nodes 2>/dev/null | awk 'NR>1{printf "  %-20s CPU: %s/%s  Mem: %s/%s\n", $1, $3, $2, $5, $4}'

# 2. 节点磁盘使用率
echo ""
echo ">>> 磁盘使用率(>80%告警):"
for node in $(kubectl get nodes -o name | sed 's|node/||'); do
  kubectl describe node "$node" 2>/dev/null | grep -A5 "Conditions:" | grep -q "MemoryPressure.*True" &&     echo "  ⚠️  $node 内存压力!" || true
done
df -h / /data 2>/dev/null | awk 'NR>1 && int($5)>80{printf "  ⚠️  %s 使用率 %s (%s可用)\n", $6, $5, $4}'

# 3. MySQL连接数
echo ""
echo ">>> MySQL连接使用率:"
mysql --defaults-extra-file=<(printf "[client]\nuser=root\npassword=%s\n" "${MYSQL_ROOT_PASSWORD:-}") -e "SHOW STATUS LIKE 'Threads_connected'" -N 2>/dev/null |   awk '{printf "  当前连接: %s (max: 2000, 使用率: %.1f%%)\n", $2, $2/2000*100}'

# 4. Redis内存使用率
echo ""
echo ">>> Redis内存使用率:"
for port in 6379 6380 6381; do
  used=$(redis-cli -p $port info memory 2>/dev/null | grep used_memory_human | cut -d: -f2 | tr -d '\r')
  max=$(redis-cli -p $port config get maxmemory 2>/dev/null | tail -1)
  [ -n "$used" ] && echo "  Redis-$port: 已用 $used"
done

# 5. ES磁盘使用率
echo ""
echo ">>> Elasticsearch磁盘:"
curl -s "http://localhost:9200/_cat/allocation?v" 2>/dev/null | awk 'NR>1{printf "  节点 %s: 磁盘 %s (已用%s)\n", $1, $3, $4}'

# 6. 告警汇总
echo ""
echo ">>> 扩容建议:"
echo "  如CPU>70%持续5分钟 → 考虑扩容Worker节点"
echo "  如内存>80%持续5分钟 → 检查内存泄漏或调整request/limit"
echo "  如磁盘>80% → 清理日志或扩容PV"
echo "  如MySQL连接>80% → 增加max_connections或引入连接池"

echo ""
echo "巡检完成"
```

### crontab配置
```bash
# 每天上午9点自动巡检
0 9 * * * /opt/scripts/capacity-check.sh >> /var/log/capacity-check.log 2>&1
```
## 扩容方案
- K8s Worker: 添加节点+自动调度
- MySQL: 读写分离+从库扩容
- Redis: 集群扩容(添加分片)
- ES: 添加数据节点+ILM策略
- 存储: NFS扩容或迁移到分布式存储
