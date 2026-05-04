# 灾备演练SOP

## 演练频率
- 每季度1次全量演练
- 每月1次备份恢复验证

## 演练checklist

### 1. MySQL灾备演练
- [ ] 验证全量备份完整性(checksum)
- [ ] 验证binlog备份连续性
- [ ] 在测试环境执行PITR恢复
- [ ] 验证恢复后数据一致性
- [ ] 记录恢复时间(RTO)

### 2. Redis灾备演练
- [ ] 验证RDB备份完整性
- [ ] 验证AOF备份
- [ ] 在测试环境执行数据恢复
- [ ] 验证集群状态
- [ ] 记录恢复时间(RTO)

### 3. K8s etcd灾备演练
- [ ] 验证etcd快照备份
- [ ] 在测试环境执行etcd恢复
- [ ] 验证集群状态
- [ ] 记录恢复时间(RTO)

### 4. Harbor灾备演练
- [ ] 验证镜像数据备份
- [ ] 在测试环境执行Harbor恢复
- [ ] 验证镜像可拉取
- [ ] 记录恢复时间(RTO)

## 回滚决策树
1. 恢复失败 → 检查备份完整性 → 使用更早的备份
2. 恢复超时 → 分段恢复 → 优先恢复核心服务
3. 数据不一致 → 停止写入 → 人工修复

## 演练报告模板
- 演练日期:
- 演练范围:
- RTO目标 vs 实际:
- RPO目标 vs 实际:
- 发现问题:
- 改进措施:

## 灾备演练清单

### 演练频率
| 场景 | 频率 | 负责人 |
|------|------|--------|
| etcd备份恢复 | 季度 | SRE |
| MySQL MGR主从切换 | 月度 | DBA |
| ES集群故障恢复 | 季度 | SRE |
| Redis Cluster节点替换 | 季度 | SRE |
| 全站灾备切换 | 半年 | 架构师 |

### 演练步骤模板

#### MySQL MGR Failover演练
1. 记录当前Primary节点: `SELECT * FROM replication_group_members;`
2. 停止Primary: `systemctl stop mysqld` on primary
3. 等待自动切换: `SELECT MEMBER_STATE FROM replication_group_members;`
4. 验证新Primary可写: `INSERT INTO test.test_table VALUES (1);`
5. 恢复旧Primary: `systemctl start mysqld`
6. 验证自动加入: `SELECT * FROM replication_group_members;`
7. 记录RTO: 从停止到恢复写入的时间

#### Redis Cluster节点故障演练
1. 记录当前slot分布: `redis-cli cluster slots`
2. 停止一个master: `redis-cli -h NODE -p PORT shutdown`
3. 等待故障转移: `redis-cli cluster info | grep cluster_state`
4. 验证数据可读写
5. 恢复节点: `redis-cli --cluster add-node NEW:PORT EXISTING:PORT`
6. 验证slot重新分配

---

## 混沌工程基础

### 混沌工程原则

> 混沌工程不是"随便搞破坏"，而是通过可控的故障注入验证系统的韧性。

### 常用混沌工具

| 工具 | 适用场景 | 安装方式 |
|------|---------|---------|
| Chaos Mesh | K8s Pod/网络/IO故障 | Helm install |
| Litmus Chaos | K8s原生混沌工程 | Helm install |
| tc/netem | 网络延迟/丢包 | Linux自带 |
| stress-ng | CPU/内存压力 | yum install |

### 故障注入清单

| 故障类型 | 注入方式 | 验证目标 | 回滚方式 |
|---------|---------|---------|---------|
| Pod杀死 | `kubectl delete pod` | 自动恢复、HPA生效 | 无(自动重建) |
| 网络延迟 | `tc qdisc add dev eth0 root netem delay 100ms` | 超时重试机制 | `tc qdisc del` |
| 网络丢包 | `tc qdisc add dev eth0 root netem loss 10%` | 重试+降级策略 | `tc qdisc del` |
| CPU满载 | `stress-ng --cpu 4 --timeout 60s` | HPA扩容、资源限制 | 超时自动停止 |
| 磁盘满 | `dd if=/dev/zero of=/tmp/fill bs=1M count=10G` | 磁盘告警、日志轮转 | `rm /tmp/fill` |
| DNS故障 | `iptables -A OUTPUT -p udp --dport 53 -j DROP` | DNS缓存、服务发现 | `iptables -D` |

### 演练流程

1. **准备**: 选择故障类型、确定影响范围、准备回滚方案
2. **通知**: 提前通知相关团队
3. **注入**: 执行故障注入
4. **观察**: 监控告警是否触发、服务是否降级
5. **恢复**: 执行回滚、验证服务恢复
6. **复盘**: 记录发现的问题、改进措施
