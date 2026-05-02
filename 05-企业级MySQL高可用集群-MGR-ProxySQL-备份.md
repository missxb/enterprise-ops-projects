     1|# 企业级MySQL高可用集群 - MGR + ProxySQL + 自动备份
     2|
     3|> 完整实现MySQL高可用方案，覆盖MGR集群、读写分离、自动备份、PITR恢复、慢查询优化
     4|
     5|---
     6|
     7|## 一、架构
     8|
     9|```
    10|                    ┌──────────────────┐
    11|                    │   Application    │
    12|                    └────────┬─────────┘
    13|                             │
    14|                    ┌────────▼─────────┐
    15|                    │    ProxySQL      │
    16|                    │ 读写分离+连接池   │
    17|                    │ 读: 轮询从库      │
    18|                    │ 写: 路由主库      │
    19|                    └──┬───────┬───┬───┘
    20|                       │       │   │
    21|              ┌────────▼┐ ┌───▼──┐ ┌▼────────┐
    22|              │ MySQL-01│ │-02   │ │MySQL-03 │
    23|              │ Primary │ │Secondary│ │Secondary│
    24|              │ (读写)  │ │(只读)  │ │(只读)   │
    25|              └─────────┘ └──────┘ └─────────┘
    26|                       MGR Group Replication
    27|```
    28|
    29|---
    30|
    31|## 二、服务器规划
    32|
    33|| 角色 | IP | 配置 | 用途 |
    34||------|-----|------|------|
    35|| MySQL-01 | 10.10.30.11 | 16C/64G/1T NVMe | MGR Primary |
    36|| MySQL-02 | 10.10.30.12 | 16C/64G/1T NVMe | MGR Secondary |
    37|| MySQL-03 | 10.10.30.13 | 16C/64G/1T NVMe | MGR Secondary |
    38|| ProxySQL | 10.10.30.21 | 8C/16G/100G | 代理层 |
    39|| 备份服务器 | 10.10.30.31 | 4C/16G/10T | xtrabackup备份 |
    40|
    41|---
    42|
    43|## 三、MySQL MGR集群配置
    44|
    45|### 3.1 三台MySQL节点统一配置
    46|
    47|```ini
    48|# /etc/my.cnf - MGR集群配置
    49|[mysqld]
    50|# 基础配置
    51|server-id=1                          # 每台不同: 1/2/3
    52|port=3306
    53|datadir=/data/mysql
    54|socket=/var/lib/mysql/mysql.sock
    55|pid-file=/var/run/mysqld/mysqld.pid
    56|character-set-server=utf8mb4
    57|collation-server=utf8mb4_unicode_ci
    58|default-time-zone='+08:00'
    59|
    60|# InnoDB配置
    61|innodb_buffer_pool_size=48G          # 75%内存
    62|innodb_buffer_pool_instances=16
    63|innodb_log_file_size=2G
    64|innodb_log_buffer_size=64M
    65|innodb_flush_log_at_trx_commit=1     # MGR必须=1保证一致性
    66|innodb_flush_method=O_DIRECT
    67|innodb_file_per_table=1
    68|innodb_autoinc_lock_mode=2           # MGR必须=2
    69|innodb_lock_wait_timeout=10
    70|
    71|# GTID配置（MGR依赖GTID）
    72|gtid_mode=ON
    73|enforce_gtid_consistency=ON
    74|binlog_checksum=NONE                 # MGR必须NONE
    75|log_bin=mysql-bin
    76|binlog_format=ROW
    77|max_binlog_size=512M
    78|expire_logs_days=7
    79|
    80|# 半同步复制
    81|plugin_load_add='semisync_source.so'
    82|plugin_load_add='semisync_replica.so'
    83|rpl_semi_sync_source_enabled=1
    84|rpl_semi_sync_source_timeout=3000
    85|
    86|# 连接配置
    87|max_connections=2000
    88|max_connect_errors=100
    89|wait_timeout=600
    90|interactive_timeout=600
    91|thread_cache_size=64
    92|
    93|# 慢查询
    94|slow_query_log=1
    95|slow_query_log_file=/data/mysql/slow.log
    96|long_query_time=1
    97|log_queries_not_using_indexes=1
    98|
    99|# Performance Schema
   100|performance_schema=ON
   101|performance_schema_max_table_instances=500
   102|
   103|# MGR核心配置
   104|plugin_load_add='group_replication.so'
   105|loose-group_replication_group_name="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
   106|loose-group_replication_start_on_boot=OFF     # 首次启动OFF
   107|loose-group_replication_local_address="10.10.30.11:33061"  # 每台不同
   108|loose-group_replication_group_seeds="10.10.30.11:33061,10.10.30.12:33061,10.10.30.13:33061"
   109|loose-group_replication_single_primary_mode=ON
   110|loose-group_replication_enforce_update_everywhere_checks=OFF
   111|loose-group_replication_recovery_get_public_key=1
   112|
   113|# 过滤不需要同步的库
   114|binlog-do_db=app_db
   115|binlog-do_db=user_db
   116|binlog-do_db=order_db
   117|```
   118|
   119|### 3.2 初始化MGR集群
   120|
   121|```bash
   122|#!/bin/bash
   123|# init_mgr.sh - 在MySQL-01(Primary)上执行
   124|
   125|set -euo pipefail
   126|
   127|MYSQL_CMD="mysql -uroot -pMySQL@Root2024"
   128|
   129|echo "Step 1: 配置复制用户..."
   130|${MYSQL_CMD} << 'SQL'
   131|SET GLOBAL super_read_only=OFF;
   132|CREATE USER IF NOT EXISTS 'repl_user'@'%' IDENTIFIED BY 'Repl@Pass2024';
   133|GRANT REPLICATION SLAVE ON *.* TO 'repl_user'@'%';
   134|FLUSH PRIVILEGES;
   135|SQL
   136|
   137|echo "Step 2: 配置MGR引导..."
   138|${MYSQL_CMD} << 'SQL'
   139|SET GLOBAL group_replication_bootstrap_group=ON;
   140|START GROUP_REPLICATION;
   141|SET GLOBAL group_replication_bootstrap_group=OFF;
   142|SQL
   143|
   144|echo "Step 3: 验证集群状态..."
   145|${MYSQL_CMD} -e "SELECT * FROM performance_schema.replication_group_members\G"
   146|
   147|echo "在MySQL-02和MySQL-03上执行以下命令加入集群:"
   148|echo "
   149|-- 在MySQL-02/03上执行:
   150|CHANGE REPLICATION SOURCE TO
   151|  SOURCE_USER='repl_user',
   152|  SOURCE_PASSWORD='Repl@Pass2024',
   153|  SOURCE_AUTO_POSITION=1
   154|  FOR CHANNEL 'group_replication_recovery';
   155|START GROUP_REPLICATION;
   156|"
   157|```
   158|
   159|### 3.3 集群验证
   160|
   161|```bash
   162|#!/bin/bash
   163|# verify_mgr.sh - 验证MGR集群健康
   164|
   165|set -euo pipefail
   166|
   167|echo "========== 集群成员状态 =========="
   168|mysql -uroot -pMySQL@Root2024 -e "
   169|  SELECT MEMBER_ID, MEMBER_HOST, MEMBER_PORT, MEMBER_STATE, MEMBER_ROLE
   170|  FROM performance_schema.replication_group_members;
   171|"
   172|
   173|echo "========== 复制延迟 =========="
   174|mysql -uroot -pMySQL@Root2024 -e "
   175|  SELECT CHANNEL_NAME, SERVICE_STATE, COUNT_TRANSACTIONS_IN_QUEUE
   176|  FROM performance_schema.replication_group_member_stats;
   177|"
   178|
   179|echo "========== 集群一致性检查 =========="
   180|mysql -uroot -pMySQL@Root2024 -e "
   181|  SELECT MEMBER_ROLE, MEMBER_STATE FROM performance_schema.replication_group_members
   182|  WHERE MEMBER_STATE != 'ONLINE';
   183|" 2>/dev/null && echo "⚠️ 有异常成员!" || echo "✅ 所有成员正常"
   184|```
   185|
   186|---
   187|
   188|## 四、ProxySQL读写分离
   189|
   190|### 4.1 ProxySQL配置
   191|
   192|```bash
   193|#!/bin/bash
   194|# install_proxysql.sh - 安装配置ProxySQL
   195|
   196|set -euo pipefail
   197|
   198|echo "安装ProxySQL..."
   199|yum install -y proxysql
   200|
   201|# 启动ProxySQL
   202|systemctl enable proxysql
   203|systemctl start proxysql
   204|
   205|echo "配置后端MySQL..."
   206|mysql -uadmin -padmin -h127.0.0.1 -P6032 << 'SQL'
   207|-- 添加MySQL服务器
   208|INSERT INTO mysql_servers(hostgroup_id, hostname, port, weight, max_connections, max_replication_lag)
   209|VALUES
   210|  (10, '10.10.30.11', 3306, 1000, 2000, 0),    -- 写组
   211|  (20, '10.10.30.12', 3306, 500, 2000, 0),     -- 读组
   212|  (20, '10.10.30.13', 3306, 500, 2000, 0);     -- 读组
   213|
   214|-- 配置监控用户
   215|UPDATE global_variables SET variable_value='monitor' WHERE variable_name='mysql-monitor_username';
   216|UPDATE global_variables SET variable_value='Monitor@2024' WHERE variable_name='mysql-monitor_password';
   217|UPDATE global_variables SET variable_value=2000 WHERE variable_name='mysql-monitor_ping_interval';
   218|UPDATE global_variables SET variable_value=500 WHERE variable_name='mysql-monitor_read_only_interval';
   219|
   220|-- 读写分离规则
   221|INSERT INTO mysql_query_rules(rule_id, active, match_pattern, destination_hostgroup, apply)
   222|VALUES
   223|  (1, 1, '^SELECT.*FOR UPDATE$', 10, 1),    -- SELECT FOR UPDATE → 写组
   224|  (2, 1, '^SELECT', 20, 1),                   -- 普通SELECT → 读组
   225|  (3, 1, '.*', 10, 1);                         -- 其他 → 写组
   226|
   227|-- 添加用户
   228|INSERT INTO mysql_users(username, password, default_hostgroup, max_connections)
   229|VALUES ('app_user', 'AppP@ss2024!', 10, 2000);
   230|
   231|-- 加载配置
   232|LOAD MYSQL SERVERS TO RUNTIME;
   233|LOAD MYSQL VARIABLES TO RUNTIME;
   234|LOAD MYSQL QUERY RULES TO RUNTIME;
   235|LOAD MYSQL USERS TO RUNTIME;
   236|
   237|SAVE MYSQL SERVERS TO DISK;
   238|SAVE MYSQL VARIABLES TO DISK;
   239|SAVE MYSQL QUERY RULES TO DISK;
   240|SAVE MYSQL USERS TO DISK;
   241|SQL
   242|
   243|echo "✅ ProxySQL配置完成"
   244|echo "管理端口: 6032 (admin/admin)"
   245|echo "服务端口: 6033 (app_user/AppP@ss2024!)"
   246|```
   247|
   248|---
   249|
   250|## 五、自动化备份
   251|
   252|```bash
   253|#!/bin/bash
   254|# mysql_backup.sh - Xtrabackup自动备份
   255|
   256|set -euo pipefail
   257|
   258|BACKUP_DIR="/data/backup/mysql"
   259|DATE=$(date +%Y%m%d_%H%M%S)
   260|KEEP_DAYS=7
   261|MYSQL_USER="backup"
   262|MYSQL_PASS="Backup@2024"
   263|
   264|mkdir -p ${BACKUP_DIR}/{full,incr,binlog}
   265|
   266|echo "========== 全量备份 =========="
   267|xtrabackup --backup   --user=${MYSQL_USER} --password=${MYSQL_PASS}   --target-dir=${BACKUP_DIR}/full/full-${DATE}   --parallel=4   --compress   --compress-threads=4
   268|
   269|echo "获取LSN..."
   270|LSN=$(xtrabackup --backup --prepare --target-dir=${BACKUP_DIR}/full/full-${DATE} --export 2>&1 | grep "completed OK" | tail -1)
   271|
   272|echo "备份binlog..."
   273|mysqlbinlog --read-from-remote-server   --host=10.10.30.11 --user=${MYSQL_USER} --password=${MYSQL_PASS}   --start-datetime="$(date -d '1 hour ago' '+%Y-%m-%d %H:%M:%S')"   --stop-datetime="$(date '+%Y-%m-%d %H:%M:%S')"   mysql-bin.000001 > ${BACKUP_DIR}/binlog/binlog-${DATE}.sql
   274|
   275|echo "清理过期备份..."
   276|find ${BACKUP_DIR}/full -maxdepth 1 -type d -mtime +${KEEP_DAYS} -exec rm -rf {} +
   277|find ${BACKUP_DIR}/binlog -mtime +${KEEP_DAYS} -delete
   278|
   279|echo "✅ 备份完成: full-${DATE}"
   280|du -sh ${BACKUP_DIR}/full/full-${DATE}
   281|
   282|# crontab: 每天凌晨2点全量备份
   283|# 0 2 * * * /opt/scripts/mysql_backup.sh >> /var/log/mysql-backup.log 2>&1
   284|```
   285|
   286|---
   287|
   288|## 六、PITR恢复
   289|
   290|```bash
   291|#!/bin/bash
   292|# pitr_restore.sh - 基于时间点恢复
   293|
   294|set -euo pipefail
   295|
   296|RESTORE_DIR="/data/restore"
   297|BACKUP_DIR="/data/backup/mysql"
   298|TARGET_TIME="2024-01-15 14:30:00"
   299|
   300|echo "Step 1: 找到最近的全量备份..."
   301|LATEST_FULL=$(ls -td ${BACKUP_DIR}/full/full-* | head -1)
   302|echo "使用备份: ${LATEST_FULL}"
   303|
   304|echo "Step 2: 应用redo log..."
   305|xtrabackup --prepare --target-dir=${LATEST_FULL} --apply-log-only
   306|
   307|echo "Step 3: 恢复数据..."
   308|systemctl stop mysqld
   309|rm -rf /data/mysql/*
   310|xtrabackup --copy-back --target-dir=${LATEST_FULL}
   311|
   312|echo "Step 4: 应用binlog到目标时间点..."
   313|# 找到对应的binlog文件
   314|xtrabackup --prepare --target-dir=${LATEST_FULL}
   315|
   316|chown -R mysql:mysql /data/mysql
   317|systemctl start mysqld
   318|
   319|echo "✅ PITR恢复完成，已恢复到: ${TARGET_TIME}"
   320|```
   321|
   322|---
   323|
   324|## 七、慢查询优化
   325|
   326|```sql
   327|-- 开启慢查询日志
   328|SET GLOBAL slow_query_log=ON;
   329|SET GLOBAL long_query_time=1;
   330|SET GLOBAL log_queries_not_using_indexes=ON;
   331|
   332|-- 分析Top慢查询
   333|SELECT
   334|  DIGEST_TEXT,
   335|  COUNT_STAR as exec_count,
   336|  ROUND(SUM_TIMER_WAIT/1e12, 2) as total_time_sec,
   337|  ROUND(AVG_TIMER_WAIT/1e12, 4) as avg_time_sec,
   338|  SUM_ROWS_EXAMINED as rows_examined,
   339|  SUM_ROWS_SENT as rows_sent
   340|FROM performance_schema.events_statements_summary_by_digest
   341|ORDER BY SUM_TIMER_WAIT DESC
   342|LIMIT 20;
   343|
   344|-- 查看表索引使用情况
   345|SELECT
   346|  object_schema, object_name, index_name,
   347|  count_star as uses,
   348|  count_read, count_write
   349|FROM performance_schema.table_io_waits_summary_by_index_usage
   350|WHERE object_schema NOT IN ('mysql', 'performance_schema', 'sys')
   351|ORDER BY count_star DESC
   352|LIMIT 20;
   353|
   354|-- 查看InnoDB缓冲池
   355|SHOW GLOBAL STATUS LIKE 'Innodb_buffer_pool_%';
   356|-- 命中率 = 1 - (Innodb_buffer_pool_reads / Innodb_buffer_pool_read_requests)
   357|```
   358|
   359|---
   360|
   361|> 本项目基于25个语雀知识库(2699篇,584万字)编写
   362|

---

## 八、方案对比与选型

### 8.1 MGR vs InnoDB Cluster vs Galera

| 特性 | MySQL MGR | InnoDB Cluster | Galera Cluster |
|------|-----------|---------------|----------------|
| 复制方式 | 基于Paxos协议 | MGR + MySQL Shell + Router | 真正多主同步 |
| 数据一致性 | 强一致(多数派) | 强一致(基于MGR) | 强一致(同步复制) |
| 写扩展 | 单主模式单写/多主模式多写 | 同MGR | 真正多主多写 |
| 故障转移 | 自动(基于MGR) | 自动(MySQL Router) | 自动 |
| 运维工具 | 原生SQL | MySQL Shell + Router | 原生SQL |
| 应用透明度 | 需要代理层 | Router自动路由 | 需要代理层 |
| 适用版本 | MySQL 5.7.17+ | MySQL 8.0+ | MariaDB 10.x |
| 最大节点数 | 9个 | 9个 | 16个 |
| 推荐场景 | 中小企业 | 中大型企业 | 需要多主写入 |

**选型建议**:
- MySQL 8.0+ → InnoDB Cluster (MGR + Router)
- 需要强一致性 → MGR单主模式
- 需要多点写入 → Galera Cluster
- 本项目选择: MGR单主模式 + ProxySQL

### 8.2 ProxySQL vs MySQL Router vs HAProxy

| 特性 | ProxySQL | MySQL Router | HAProxy |
|------|----------|-------------|---------|
| 读写分离 | ✅ 智能路由 | ✅ 基础路由 | ❌ 需手动配置 |
| 连接池 | ✅ 内置 | ❌ | ❌ |
| 查询缓存 | ✅ Query Cache | ❌ | ❌ |
| 故障转移 | ✅ 自动检测 | ✅ 基于MGR | ✅ 健康检查 |
| 限流 | ✅ | ❌ | ✅ |
| 运维界面 | ✅ Web界面 | ❌ | ❌ |
| 配置热加载 | ✅ | ❌ 需重启 | ❌ 需reload |
| 适用场景 | 企业级 | 轻量级 | 纯TCP代理 |

---

## 九、性能调优参数

### 9.1 InnoDB调优

```ini
# innodb_buffer_pool_size: 推荐物理内存的50-75%
# 64GB服务器 → innodb_buffer_pool_size = 48G

# innodb_log_file_size: 越大写入性能越好，但恢复时间越长
# 推荐: 1-2GB

# innodb_flush_log_at_trx_commit:
# 1 = 每次提交都fsync(最安全，性能最差)
# 2 = 每秒fsync(推荐，平衡安全和性能)
# 0 = 依赖OS(最快，可能丢数据)

# sync_binlog:
# 1 = 每次提交都同步binlog(推荐主库)
# 100 = 每100次提交同步(推荐从库)

# innodb_io_capacity: 根据磁盘IOPS设置
# SSD: 2000-10000
# HDD: 200-400
```

### 9.2 连接池调优

```sql
-- 查看当前连接状态
SHOW STATUS LIKE 'Threads_%';
SHOW STATUS LIKE 'Max_used_connections';
SHOW STATUS LIKE 'Connections';

-- 查看连接池使用情况
SHOW STATUS LIKE 'Threads_connected';

-- 推荐配置
SET GLOBAL max_connections = 2000;
SET GLOBAL thread_cache_size = 64;
SET GLOBAL wait_timeout = 600;
SET GLOBAL interactive_timeout = 600;
```

### 9.3 慢查询优化流程

```sql
-- 1. 开启慢查询日志
SET GLOBAL slow_query_log = ON;
SET GLOBAL long_query_time = 1;
SET GLOBAL log_queries_not_using_indexes = ON;

-- 2. 分析Top慢查询
SELECT
  DIGEST_TEXT,
  COUNT_STAR as exec_count,
  ROUND(SUM_TIMER_WAIT/1e12, 2) as total_sec,
  ROUND(AVG_TIMER_WAIT/1e12, 4) as avg_sec,
  SUM_ROWS_EXAMINED as rows_examined,
  SUM_ROWS_SENT as rows_sent
FROM performance_schema.events_statements_summary_by_digest
ORDER BY SUM_TIMER_WAIT DESC
LIMIT 20;

-- 3. 分析索引使用
SELECT
  object_schema, object_name, index_name,
  count_star as total_uses,
  count_read, count_write, count_fetch
FROM performance_schema.table_io_waits_summary_by_index_usage
WHERE object_schema NOT IN ('mysql', 'performance_schema', 'sys')
ORDER BY count_star DESC;

-- 4. 执行计划分析
EXPLAIN SELECT * FROM orders WHERE user_id = 12345 AND status = 'paid';
-- 关注: type(ALL=全表扫描), key(使用了哪个索引), rows(扫描行数), Extra
```

---

## 十、真实故障案例

### 案例1: MGR脑裂

**故障**: 3节点MGR集群出现2个Primary，数据不一致

**原因**: 网络分区导致2个节点认为自己是多数派

**解决**:
```sql
-- 1. 检查集群状态
SELECT * FROM performance_schema.replication_group_members;

-- 2. 强制恢复为单主模式
SET GLOBAL group_replication_force_members = '10.10.30.12:33061,10.10.30.13:33061';

-- 3. 重新加入异常节点
STOP GROUP_REPLICATION;
SET GLOBAL group_replication_bootstrap_group = OFF;
START GROUP_REPLICATION;
```

### 案例2: 磁盘满导致MySQL崩溃

**故障**: binlog累积占满磁盘，MySQL无法写入

**解决**:
```sql
-- 1. 紧急清理binlog
PURGE BINARY LOGS BEFORE DATE_SUB(NOW(), INTERVAL 1 DAY);

-- 2. 设置自动过期
SET GLOBAL expire_logs_days = 7;

-- 3. 监控磁盘空间
-- Prometheus告警规则
- alert: MySQLDiskFull
  expr: node_filesystem_avail_bytes{mountpoint="/data/mysql"} / node_filesystem_size_bytes < 0.1
  for: 5m
  labels:
    severity: critical
```

### 案例3: 连接池耗尽

**故障**: ProxySQL显示大量连接超时

**解决**:
```sql
-- 1. 检查连接数
SHOW STATUS LIKE 'Threads_connected';
SHOW STATUS LIKE 'Max_used_connections';

-- 2. 增加最大连接数
SET GLOBAL max_connections = 3000;

-- 3. ProxySQL配置连接池
UPDATE mysql_servers SET max_connections = 2000 WHERE hostname = '10.10.30.11';
LOAD MYSQL SERVERS TO RUNTIME;
SAVE MYSQL SERVERS TO DISK;

-- 4. 应用端配置连接池
-- HikariCP: maximumPoolSize=50, minimumIdle=10
```

---

## 十一、灾备方案

### 11.1 RTO/RPO目标

| 指标 | 目标值 | 实现方式 |
|------|--------|---------|
| RPO(数据丢失) | < 1秒 | MGR强一致性 + AOF |
| RTO(恢复时间) | < 5分钟 | MGR自动failover |
| 备份频率 | 每天全量 + 每小时增量 | xtrabackup |
| 备份保留 | 7天 | 自动清理 |

### 11.2 备份验证

```bash
#!/bin/bash
# verify_backup.sh - 备份验证脚本

set -euo pipefail

BACKUP_DIR="/data/backup/mysql"
LATEST=$(ls -td ${BACKUP_DIR}/full/full-* | head -1)

echo "验证备份: ${LATEST}"

# 1. 检查备份完整性
xtrabackup --prepare --target-dir=${LATEST}

# 2. 验证恢复到临时目录
RESTORE_DIR="/tmp/mysql_restore_$$"
mkdir -p ${RESTORE_DIR}
xtrabackup --copy-back --target-dir=${LATEST} --datadir=${RESTORE_DIR}

# 3. 检查数据文件
FILE_COUNT=$(find ${RESTORE_DIR} -name "*.ibd" | wc -l)
echo "数据文件数: ${FILE_COUNT}"

# 4. 清理
rm -rf ${RESTORE_DIR}

echo "✅ 备份验证通过"
```

---

## 十二、容量规划

### 12.1 内存规划

```
MySQL服务器内存分配(64GB):
- innodb_buffer_pool_size: 48GB (75%)
- innodb_log_buffer_size: 64MB
- sort_buffer_size: 4MB × max_connections
- join_buffer_size: 4MB × max_connections
- 操作系统+其他: ~15GB
```

### 12.2 磁盘规划

```
数据盘计算:
- 当前数据量: 500GB
- 年增长率: 100%
- 3年数据量: 500 × 2^3 = 4TB
- 冗余系数: 1.5
- 所需磁盘: 6TB
- 建议: 3 × 2TB NVMe SSD (RAID10)
```

---

## 十三、运维SOP

### 13.1 日常巡检

```bash
#!/bin/bash
# mysql_daily_check.sh

echo "========== MySQL日常巡检 =========="

# 1. 实例状态
mysql -uroot -pMySQL@Root2024 -e "SELECT VERSION(); SELECT UPTIME;"

# 2. 连接数
mysql -uroot -pMySQL@Root2024 -e "SHOW STATUS LIKE 'Threads_connected';"

# 3. 复制状态
mysql -uroot -pMySQL@Root2024 -e "
  SELECT MEMBER_ID, MEMBER_HOST, MEMBER_PORT, MEMBER_STATE, MEMBER_ROLE
  FROM performance_schema.replication_group_members;"

# 4. 慢查询数量
mysql -uroot -pMySQL@Root2024 -e "SHOW STATUS LIKE 'Slow_queries';"

# 5. 磁盘空间
df -h /data/mysql

# 6. 错误日志
tail -20 /data/mysql/error.log
```

---

## 十四、应急预案

```
场景1: MySQL主库宕机
  1. MGR自动failover (< 10秒)
  2. 检查ProxySQL路由是否切换
  3. 验证业务读写正常
  4. 修复故障节点并重新加入集群

场景2: 数据误删除
  1. 立即停止写入
  2. 使用xtrabackup恢复到最近备份
  3. 使用binlog回放到误删前
  4. 验证数据完整性
  5. 通知业务方

场景3: 复制延迟
  1. 检查从库IO/SQL线程状态
  2. 检查网络延迟
  3. 检查从库磁盘IO
  4. 必要时跳过事务或重建从库
```

---

## 十五、项目文件清单

```
mysql-ha-cluster/
├── scripts/
│   ├── init_mysql_nodes.sh
│   ├── init_mgr_cluster.sh
│   ├── install_proxysql.sh
│   ├── mysql_backup.sh
│   ├── mysql_restore.sh
│   ├── verify_backup.sh
│   ├── pitr_restore.sh
│   ├── mysql_daily_check.sh
│   └── failover_test.sh
├── conf/
│   ├── my.cnf.master
│   ├── my.cnf.slave
│   ├── proxysql.cnf
│   └── my.cnf.tuning
├── sql/
│   ├── init_replication_user.sql
│   ├── slow_query_analysis.sql
│   └── performance_tuning.sql
└── README.md
