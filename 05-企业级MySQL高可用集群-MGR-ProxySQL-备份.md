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
    80|# [已修复] MGR内部使用Paxos协议同步，不需要半同步复制
# 半同步复制(semisync)与MGR会冲突，已移除
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
   114|# [已禁用] MGR不兼容binlog-do_db
# binlog-do_db=app_db
   115|# binlog-do_db=user_db
   116|# binlog-do_db=order_db
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

> ⚠️ **安全声明**: 本文档中的密码(如MySQL@Root2024、Harbor12345等)均为示例占位符。
> 生产环境必须使用密钥管理工具(Vault/K8s Secrets/环境变量)管理敏感信息，
> 切勿将真实密码硬编码在配置文件或脚本中。

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


---

## 十六、更多真实故障案例

### 案例4: 大事务导致主从延迟

**故障现象**: ProxySQL监控显示从库复制延迟从0飙升到300秒，业务查询读到旧数据

**根因分析**:
```bash
# 查看复制状态
mysql -uroot -pMySQL@Root2024 -e "
  SHOW REPLICA STATUS\G
" | grep -E "Seconds_Behind_Master|Slave_SQL_Running|Exec_Master_Log_Pos"

# Seconds_Behind_Master: 300
# Slave_SQL_Running: Yes
# 发现: 一个DELETE大表操作(删除1000万行)导致从库重放慢
```

**处理步骤**:
```sql
-- 1. 在从库查看当前执行的SQL
SHOW PROCESSLIST;
-- 找到正在执行的大DELETE语句

-- 2. 临时跳过该事务(危险操作，需确认数据一致性)
STOP SLAVE;
SET GLOBAL sql_replica_skip_counter = 1;
START SLAVE;

-- 3. 验证复制状态
SHOW REPLICA STATUS\G

-- 4. 在主库优化大事务
-- 将大DELETE拆分为小批次
DELETE FROM logs WHERE created_at < '2023-01-01' LIMIT 10000;
-- 循环执行直到删除完成

-- 5. 设置大事务告警
-- 在my.cnf中添加:
-- binlog_transaction_dependency_tracking = WRITESET
-- transaction_write_set_extraction = XXHASH64
```

**预防措施**:
- 设置 `long_query_time=0.5` 捕捉慢查询
- 大表DDL使用 `pt-online-schema-change`
- 大DELETE/UPDATE使用分批执行

### 案例5: 复制延迟持续增长

**故障现象**: 从库复制延迟从几秒逐渐增长到几分钟，重启从库后恢复但几天后再次出现

**根因分析**:
```bash
# 查看从库线程状态
mysql -uroot -pMySQL@Root2024 -e "
  SHOW REPLICA STATUS\G
" | grep -E "Slave_IO_Running|Slave_SQL_Running|Last_Error"

# Slave_IO_Running: Yes
# Slave_SQL_Running: Yes
# Last_Error: (空)
# 发现: IO线程和SQL线程都正常，但延迟持续增长

# 查看从库磁盘IO
iostat -x 1 5
# 发现: 磁盘IO利用率达到98%，写延迟高

# 查看InnoDB状态
mysql -uroot -pMySQL@Root2024 -e "
  SHOW ENGINE INNODB STATUS\G
" | grep -A5 "SEMAPHORES"

# 发现: 大量行锁等待
```

**处理步骤**:
```sql
-- 1. 检查从库是否有长事务
SELECT * FROM information_schema.innodb_trx 
WHERE TIME_TO_SEC(TIMEDIFF(NOW(), trx_started)) > 60;

-- 2. 检查是否有锁等待
SELECT * FROM performance_schema.data_lock_waits;

-- 3. 优化从库配置
SET GLOBAL innodb_flush_log_at_trx_commit = 2;  -- 从库可以用2
SET GLOBAL sync_binlog = 100;  -- 从库可以放宽

-- 4. 增加从库并行复制
SET GLOBAL slave_parallel_workers = 8;
SET GLOBAL slave_parallel_type = 'LOGICAL_CLOCK';
SET GLOBAL slave_preserve_commit_order = 1;
```

### 案例6: 表锁导致业务超时

**故障现象**: 应用端大量连接超时，ProxySQL监控显示写操作堆积

**根因分析**:
```bash
# 查看锁等待
mysql -uroot -pMySQL@Root2024 -e "
  SELECT 
    r.trx_id waiting_trx_id,
    r.trx_mysql_thread_id waiting_thread,
    r.trx_query waiting_query,
    b.trx_id blocking_trx_id,
    b.trx_mysql_thread_id blocking_thread,
    b.trx_query blocking_query
  FROM information_schema.innodb_lock_waits w
  INNER JOIN information_schema.innodb_trx b ON b.trx_id = w.blocking_trx_id
  INNER JOIN information_schema.innodb_trx r ON r.trx_id = w.requesting_trx_id;
"

# 发现: 
# waiting_query: "UPDATE users SET status=1 WHERE id=12345"
# blocking_query: "ALTER TABLE users ADD COLUMN new_col VARCHAR(100)"
# 原因: ALTER TABLE持有元数据锁，阻塞了所有DML操作
```

**处理步骤**:
```sql
-- 1. 查找阻塞的DDL
SELECT * FROM information_schema.processlist 
WHERE command = 'Query' AND info LIKE 'ALTER%';

-- 2. 在另一个终端杀掉DDL(如果可以接受)
KILL <blocking_thread_id>;

-- 3. 使用pt-online-schema-change代替ALTER TABLE
pt-online-schema-change \
  --alter "ADD COLUMN new_col VARCHAR(100)" \
  --user=root --password=MySQL@Root2024 \
  --host=10.10.30.11 \
  D=app_db,t=users \
  --execute

-- 4. 设置锁等待告警
-- Prometheus告警规则
-- alert: MySQLLockWait
-- expr: mysql_global_status_innodb_row_lock_waits > 100
-- for: 1m
```

### 案例7: binlog暴增导致磁盘满

**故障现象**: MySQL主库磁盘使用率从50%飙升到95%，30分钟内增长了200GB

**根因分析**:
```bash
# 查看binlog大小
ls -lh /data/mysql/mysql-bin.*
# mysql-bin.000001  200G
# mysql-bin.000002  50G
# 发现: 一个批量更新操作产生了大量binlog

# 查看binlog事件
mysqlbinlog --base64-output=DECODE-ROWS -v mysql-bin.000002 | head -100
# 发现: 大量UPDATE语句，每行产生一个binlog事件
```

**处理步骤**:
```sql
-- 1. 紧急清理binlog
PURGE BINARY LOGS BEFORE DATE_SUB(NOW(), INTERVAL 1 DAY);

-- 2. 检查当前binlog设置
SHOW VARIABLES LIKE 'expire_logs_days';
SHOW VARIABLES LIKE 'max_binlog_size';

-- 3. 优化binlog配置
SET GLOBAL expire_logs_days = 7;  -- 保留7天
SET GLOBAL max_binlog_size = 256M;  -- 每个文件最大256MB

-- 4. 对大表使用Row模式优化
-- 在my.cnf中添加:
-- binlog_row_image = MINIMAL  -- 只记录变化的列
-- binlog_row_metadata = MINIMAL

-- 5. 使用pt-heartbeat监控复制延迟
pt-heartbeat --update --database heartbeat --create-table
-- 在从库运行:
pt-heartbeat --monitor --database heartbeat
```

### 案例8: 密码策略导致连接失败

**故障现象**: 应用端突然无法连接MySQL，报错"Access denied for user"

**根因分析**:
```bash
# 查看MySQL错误日志
tail -100 /data/mysql/error.log | grep -i "access denied"

# 发现: 
# [Warning] Access denied for user 'app_user'@'10.10.30.21' (using password: YES)
# [Note] Access denied for user 'app_user'@'10.10.30.21'. (Using password: YES)

# 检查密码过期策略
mysql -uroot -pMySQL@Root2024 -e "
  SELECT user, host, password_expired, password_lifetime 
  FROM mysql.user WHERE user='app_user';
"
# password_expired: Y
# password_lifetime: 90  -- 密码90天过期
```

**处理步骤**:
```sql
-- 1. 重置密码
ALTER USER 'app_user'@'%' IDENTIFIED BY 'NewP@ss2024!';
FLUSH PRIVILEGES;

-- 2. 取消密码过期
ALTER USER 'app_user'@'%' PASSWORD EXPIRE NEVER;

-- 3. 检查密码策略
SHOW VARIABLES LIKE 'validate_password%';
-- validate_password.length = 8
-- validate_password.mixed_case_count = 1
-- validate_password.number_count = 1
-- validate_password.special_char_count = 1

-- 4. 设置密码永不过期(全局)
SET GLOBAL default_password_lifetime = 0;

-- 5. 创建密码轮换脚本
-- 每月检查密码过期时间，提前30天提醒
SELECT user, host, 
  password_last_changed,
  DATE_ADD(password_last_changed, INTERVAL 60 DAY) as reminder_date
FROM mysql.user 
WHERE password_last_changed < DATE_SUB(NOW(), INTERVAL 30 DAY);
```

---

## 十七、性能调优详细参数

### 17.1 Buffer Pool调优

```ini
# innodb_buffer_pool_size: 推荐物理内存的50-75%
# 64GB服务器 → 48GB
# 128GB服务器 → 96GB

# innodb_buffer_pool_instances: 每个实例至少1GB
# 48GB → 16个实例
innodb_buffer_pool_instances=16

# innodb_buffer_pool_chunk_size: 默认128MB
# 48GB / 16实例 / 128MB = 24 chunks
innodb_buffer_pool_chunk_size=128M

# 预热: 启动时加载缓冲池
innodb_buffer_pool_dump_at_shutdown=ON
innodb_buffer_pool_load_at_startup=ON
innodb_buffer_pool_dump_pct=40

# 监控缓冲池命中率
# SHOW GLOBAL STATUS LIKE 'Innodb_buffer_pool_%';
# 命中率 = 1 - (Innodb_buffer_pool_reads / Innodb_buffer_pool_read_requests)
# 目标: > 99%
```

### 17.2 Redo Log调优

```ini
# innodb_log_file_size: 越大写入性能越好，但恢复时间越长
# 推荐: 1-2GB (MySQL 8.0.30+支持动态调整)
innodb_log_file_size=2G

# innodb_log_files_in_group: redo log文件组数量
# MySQL 8.0.30+ 默认4个文件
innodb_log_files_in_group=4

# innodb_log_buffer_size: 日志缓冲区
# 写密集型: 64-256MB
innodb_log_buffer_size=64M

# innodb_flush_log_at_trx_commit:
# 1 = 每次提交都fsync (最安全，MGR必须)
# 2 = 每秒fsync (推荐从库)
# 0 = 依赖OS (最快，可能丢数据)
innodb_flush_log_at_trx_commit=1

# sync_binlog:
# 1 = 每次提交都同步binlog (推荐主库)
# 100 = 每100次提交同步 (推荐从库)
sync_binlog=1

# MySQL 8.0.30+ 动态调整redo log
SET GLOBAL innodb_redo_log_capacity = 8589934592;  -- 8GB
```

### 17.3 连接池调优

```sql
-- 查看当前连接状态
SHOW STATUS LIKE 'Threads_%';
SHOW STATUS LIKE 'Max_used_connections';
SHOW STATUS LIKE 'Connections';

-- 推荐配置
SET GLOBAL max_connections = 2000;
SET GLOBAL thread_cache_size = 64;
SET GLOBAL wait_timeout = 600;
SET GLOBAL interactive_timeout = 600;

-- 查看连接使用率
SELECT 
  (SELECT VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME='Threads_connected') as current,
  (SELECT VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME='Max_used_connections') as max_used,
  (SELECT VARIABLE_VALUE FROM performance_schema.global_variables WHERE VARIABLE_NAME='max_connections') as max_config;

-- 计算连接使用率
-- current / max_config * 100%
-- 如果 > 80%，需要增加max_connections
```

### 17.4 查询统计与优化

```sql
-- 使用Performance Schema监控查询
-- 1. 开启events_statements_summary_by_digest
UPDATE performance_schema.setup_consumers SET ENABLED='YES' 
WHERE NAME='events_statements_summary_by_digest';

-- 2. 查看Top 20慢查询
SELECT
  SCHEMA_NAME,
  DIGEST_TEXT,
  COUNT_STAR as exec_count,
  ROUND(SUM_TIMER_WAIT/1e12, 2) as total_time_sec,
  ROUND(AVG_TIMER_WAIT/1e12, 4) as avg_time_sec,
  SUM_ROWS_EXAMINED as rows_examined,
  SUM_ROWS_SENT as rows_sent,
  SUM_NO_INDEX_USED as no_index_used
FROM performance_schema.events_statements_summary_by_digest
WHERE SCHEMA_NAME IS NOT NULL
ORDER BY SUM_TIMER_WAIT DESC
LIMIT 20;

-- 3. 查看索引使用情况
SELECT
  object_schema, object_name, index_name,
  count_star as total_uses,
  count_read, count_write, count_fetch
FROM performance_schema.table_io_waits_summary_by_index_usage
WHERE object_schema NOT IN ('mysql', 'performance_schema', 'sys')
ORDER BY count_star DESC;

-- 4. 查找未使用的索引
SELECT
  object_schema, object_name, index_name
FROM performance_schema.table_io_waits_summary_by_index_usage
WHERE index_name IS NOT NULL
  AND count_star = 0
  AND object_schema NOT IN ('mysql', 'performance_schema', 'sys');

-- 5. 使用sys schema分析
SELECT * FROM sys.schema_unused_indexes;
SELECT * FROM sys.schema_redundant_indexes;
```

---

## 十八、同城双活架构

### 18.1 架构设计

```
                    ┌─────────────────────────────────────────┐
                    │              同城双活架构                │
                    ├─────────────────┬───────────────────────┤
                    │    机房A (主)    │    机房B (备)          │
                    │  10.10.30.0/24  │  10.10.40.0/24        │
                    ├─────────────────┼───────────────────────┤
                    │ MySQL-01 (Primary)│ MySQL-02 (Secondary) │
                    │ MySQL-03 (Secondary)│ MySQL-04 (Secondary)│
                    │ ProxySQL-01     │ ProxySQL-02           │
                    │ 备份服务器       │ 备份服务器             │
                    ├─────────────────┼───────────────────────┤
                    │        ◄── 专线互联 (延迟<2ms) ──►       │
                    └─────────────────┴───────────────────────┘

                    流量路由:
                    - 正常: 全部流量 → 机房A
                    - 故障: 切换DNS → 机房B
                    - RPO < 1秒, RTO < 30秒
```

### 18.2 双活配置

```bash
# 机房A配置 (10.10.30.0/24)
# MySQL-01: Primary
# MySQL-02: Secondary (机房A)
# MySQL-03: Secondary (机房A)

# 机房B配置 (10.10.40.0/24)
# MySQL-04: Secondary (机房B)

# MGR跨机房配置
# 在my.cnf中添加:
# loose-group_replication_local_address="10.10.30.11:33061"
# loose-group_replication_group_seeds="10.10.30.11:33061,10.10.30.12:33061,10.10.30.13:33061,10.10.40.14:33061"

# 跨机房复制延迟监控
# Prometheus告警规则
# alert: MySQLCrossDatacenterLag
# expr: mysql_slave_status_seconds_behind_master > 5
# for: 1m
# labels:
#   severity: warning
# annotations:
#   summary: "跨机房复制延迟 > 5秒"
```

### 18.3 故障切换流程

```bash
#!/bin/bash
# cross_dc_failover.sh - 跨机房故障切换

set -euo pipefail

echo "========== 跨机房故障切换 =========="

# 1. 确认主库不可用
echo "检查机房A MySQL状态..."
mysql -h 10.10.30.11 -uroot -pMySQL@Root2024 -e "SELECT 1" 2>/dev/null
if [ $? -eq 0 ]; then
    echo "❌ 主库仍可用，无需切换"
    exit 1
fi

echo "⚠️ 主库不可用，开始切换..."

# 2. 将机房B的Secondary提升为Primary
echo "提升MySQL-04为Primary..."
mysql -h 10.10.40.14 -uroot -pMySQL@Root2024 << 'SQL'
STOP GROUP_REPLICATION;
SET GLOBAL group_replication_bootstrap_group = ON;
START GROUP_REPLICATION;
SET GLOBAL group_replication_bootstrap_group = OFF;
SQL

# 3. 更新ProxySQL配置
echo "更新ProxySQL路由..."
mysql -uadmin -padmin -h127.0.0.1 -P6032 << 'SQL'
UPDATE mysql_servers SET hostname='10.10.40.14', hostgroup_id=10 WHERE hostname='10.10.30.11';
UPDATE mysql_servers SET hostname='10.10.40.14', hostgroup_id=20 WHERE hostname='10.10.30.12';
UPDATE mysql_servers SET hostname='10.10.40.14', hostgroup_id=20 WHERE hostname='10.10.30.13';
LOAD MYSQL SERVERS TO RUNTIME;
SAVE MYSQL SERVERS TO DISK;
SQL

# 4. 更新DNS
echo "更新DNS记录..."
# 将MySQL VIP从10.10.30.10切换到10.10.40.10
# 使用阿里云API或PowerDNS API更新

# 5. 验证
echo "验证切换..."
mysql -h 10.10.40.14 -uroot -pMySQL@Root2024 -e "
  SELECT MEMBER_ID, MEMBER_HOST, MEMBER_PORT, MEMBER_STATE, MEMBER_ROLE
  FROM performance_schema.replication_group_members;
"

echo "✅ 跨机房切换完成"
```

---

## 十九、成本估算

### 19.1 自建方案 vs RDS对比

| 资源类型 | 自建方案 | 阿里云RDS | 对比 |
|---------|---------|----------|------|
| MySQL主库 | 16C/64G/1T NVMe | 16C/64G/1T SSD | 自建更灵活 |
| MySQL从库 x 2 | 16C/64G/1T NVMe x 2 | 16C/64G/1T SSD x 2 | - |
| ProxySQL | 8C/16G/100G | 无需管理 | 云服务省运维 |
| 备份存储 | 10T HDD | OSS 10T | - |
| 运维人力 | 0.3人/月 | 0.1人/月 | - |
| License | 企业版费用 | 包含 | 云服务更贵 |

### 19.2 三年TCO计算

```
自建方案 (3年):
  硬件折旧 (按3年直线折旧):
    MySQL主库:      ¥8,000/月 × 36 = ¥288,000
    MySQL从库 x 2:  ¥8,000/月 × 2 × 36 = ¥576,000
    ProxySQL:       ¥2,000/月 × 36 = ¥72,000
    备份服务器:     ¥3,000/月 × 36 = ¥108,000
    
  网络带宽:
    100Mbps专线: ¥3,000/月 × 36 = ¥108,000
    
  运维人力:
    0.3人 × ¥15,000/月 × 36 = ¥162,000
    
  License:
    MySQL企业版: ¥50,000/年 × 3 = ¥150,000
    
  总计: ¥1,464,000 (约146万/3年)

云服务方案 (3年):
  阿里云RDS MySQL:
    高可用版 16C/64G: ¥12,000/月 × 36 = ¥432,000
    只读实例 x 2: ¥6,000/月 × 2 × 36 = ¥432,000
    
  备份存储:
    OSS 10T: ¥500/月 × 36 = ¥18,000
    
  网络带宽:
    100Mbps: ¥2,000/月 × 36 = ¥72,000
    
  运维人力:
    0.1人 × ¥15,000/月 × 36 = ¥54,000
    
  总计: ¥1,008,000 (约101万/3年)

结论: 云服务更便宜，但自建方案更灵活
      建议: 核心业务自建，非核心业务用RDS
```

---

## 二十、监控告警

### 20.1 Prometheus指标采集

```yaml
# mysql-exporter-deployment.yaml
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mysql-exporter
  namespace: monitoring
spec:
  replicas: 1
  selector:
    matchLabels:
      app: mysql-exporter
  template:
    metadata:
      labels:
        app: mysql-exporter
    spec:
      containers:
        - name: mysql-exporter
          image: prom/mysqld-exporter:v0.15.1
          args:
            - "--collect.auto_increment.columns"
            - "--collect.binlog_size"
            - "--collect.engine_innodb_status"
            - "--collect.global_status"
            - "--collect.global_variables"
            - "--collect.info_schema.innodb_metrics"
            - "--collect.info_schema.processlist"
            - "--collect.info_schema.query_response_time"
            - "--collect.info_schema.tables"
            - "--collect.info_schema.tablestats"
            - "--collect.perf_schema.eventsstatements"
            - "--collect.perf_schema.file_events"
            - "--collect.perf_schema.indexiowaits"
            - "--collect.perf_schema.tableiowaits"
            - "--collect.slave_status"
          env:
            - name: DATA_SOURCE_NAME
              value: "exporter:Exporter@2024@(10.10.30.11:3306)/"
          ports:
            - containerPort: 9104
              name: metrics
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 200m
              memory: 256Mi

---
apiVersion: v1
kind: Service
metadata:
  name: mysql-exporter
  namespace: monitoring
spec:
  selector:
    app: mysql-exporter
  ports:
    - port: 9104
      name: metrics
```

### 20.2 告警规则

```yaml
# mysql-alerts.yaml
groups:
  - name: mysql-alerts
    rules:
      # MySQL实例告警
      - alert: MySQLDown
        expr: mysql_up == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "MySQL实例宕机"
          description: "MySQL实例 {{ $labels.instance }} 已宕机"

      # 连接数告警
      - alert: MySQLConnectionsHigh
        expr: mysql_global_status_threads_connected / mysql_global_variables_max_connections > 0.8
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "MySQL连接数 > 80%"
          description: "实例 {{ $labels.instance }} 连接数使用率 {{ $value | humanizePercentage }}"

      # 复制延迟告警
      - alert: MySQLReplicationLag
        expr: mysql_slave_status_seconds_behind_master > 30
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "MySQL复制延迟 > 30秒"
          description: "实例 {{ $labels.instance }} 复制延迟 {{ $value }}秒"

      - alert: MySQLReplicationLagCritical
        expr: mysql_slave_status_seconds_behind_master > 300
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "MySQL复制延迟 > 5分钟"
          description: "实例 {{ $labels.instance }} 复制延迟 {{ $value }}秒"

      # 复制线程告警
      - alert: MySQLReplicationStopped
        expr: mysql_slave_status_slave_sql_running == 0 or mysql_slave_status_slave_io_running == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "MySQL复制线程停止"
          description: "实例 {{ $labels.instance }} 复制线程已停止"

      # 慢查询告警
      - alert: MySQLSlowQueries
        expr: rate(mysql_global_status_slow_queries[5m]) > 0.1
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "MySQL慢查询过多"
          description: "实例 {{ $labels.instance }} 慢查询速率 {{ $value }}/秒"

      # InnoDB缓冲池告警
      - alert: MySQLInnoDBBufferPoolLow
        expr: mysql_global_status_innodb_buffer_pool_reads / mysql_global_status_innodb_buffer_pool_read_requests < 0.01
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "MySQL InnoDB缓冲池命中率 < 99%"
          description: "实例 {{ $labels.instance }} 缓冲池命中率 {{ $value | humanizePercentage }}"

      # 磁盘空间告警
      - alert: MySQLDiskSpaceLow
        expr: node_filesystem_avail_bytes{mountpoint="/data/mysql"} / node_filesystem_size_bytes{mountpoint="/data/mysql"} < 0.15
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "MySQL磁盘空间不足15%"
          description: "实例 {{ $labels.instance }} 磁盘剩余 {{ $value | humanizePercentage }}"

      # MGR集群告警
      - alert: MGRMemberOffline
        expr: mysql_global_status_group_replication_member_status != "ONLINE"
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "MGR成员离线"
          description: "实例 {{ $labels.instance }} MGR成员状态: {{ $value }}"

      # ProxySQL告警
      - alert: ProxySQLBackendDown
        expr: proxysql_mysql_servers_hostgroup_id{hostgroup="10"} == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "ProxySQL后端MySQL不可用"
          description: "写组后端MySQL全部不可用"
```

---

## 二十一、运维SOP

### 21.1 日常巡检

```bash
#!/bin/bash
# mysql_daily_check.sh - MySQL日常巡检

echo "========== MySQL日常巡检 =========="

# 1. 实例状态
mysql -uroot -pMySQL@Root2024 -e "SELECT VERSION(); SELECT UPTIME;"

# 2. 连接数
mysql -uroot -pMySQL@Root2024 -e "
  SELECT 
    (SELECT VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME='Threads_connected') as current_conn,
    (SELECT VARIABLE_VALUE FROM performance_schema.global_variables WHERE VARIABLE_NAME='max_connections') as max_conn;
"

# 3. MGR集群状态
mysql -uroot -pMySQL@Root2024 -e "
  SELECT MEMBER_ID, MEMBER_HOST, MEMBER_PORT, MEMBER_STATE, MEMBER_ROLE
  FROM performance_schema.replication_group_members;
"

# 4. 复制延迟
mysql -uroot -pMySQL@Root2024 -e "SHOW REPLICA STATUS\G" | grep Seconds_Behind_Master

# 5. 慢查询数量
mysql -uroot -pMySQL@Root2024 -e "SHOW STATUS LIKE 'Slow_queries';"

# 6. InnoDB缓冲池命中率
mysql -uroot -pMySQL@Root2024 -e "
  SELECT 
    ROUND((1 - (
      (SELECT VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME='Innodb_buffer_pool_reads') /
      (SELECT VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME='Innodb_buffer_pool_read_requests')
    )) * 100, 2) as buffer_pool_hit_rate;
"

# 7. 磁盘空间
df -h /data/mysql

# 8. 错误日志
tail -20 /data/mysql/error.log
```

### 21.2 备份验证

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

# 4. 验证binlog
echo "检查binlog备份..."
ls -lh ${BACKUP_DIR}/binlog/

# 5. 清理
rm -rf ${RESTORE_DIR}

echo "✅ 备份验证通过"
```

### 21.3 紧急故障处理

```bash
#!/bin/bash
# emergency_fix.sh - 紧急故障处理

set -euo pipefail

echo "========== 紧急故障处理 =========="

# 场景1: MySQL主库宕机
echo "场景1: MySQL主库宕机"
echo "1. MGR自动failover (< 10秒)"
echo "2. 检查ProxySQL路由是否切换"
echo "3. 验证业务读写正常"
echo "4. 修复故障节点并重新加入集群"

# 场景2: 数据误删除
echo "场景2: 数据误删除"
echo "1. 立即停止写入"
echo "2. 使用xtrabackup恢复到最近备份"
echo "3. 使用binlog回放到误删前"
echo "4. 验证数据完整性"
echo "5. 通知业务方"

# 场景3: 复制延迟
echo "场景3: 复制延迟"
echo "1. 检查从库IO/SQL线程状态"
echo "2. 检查网络延迟"
echo "3. 检查从库磁盘IO"
echo "4. 必要时跳过事务或重建从库"

# 场景4: 磁盘满
echo "场景4: 磁盘满"
echo "1. PURGE BINARY LOGS清理binlog"
echo "2. 检查大表DDL操作"
echo "3. 清理临时表和日志"
echo "4. 扩容磁盘"
```

---

## 二十二、版本升级SOP

### 22.1 升级前准备

```bash
# 1. 检查当前版本
mysql -uroot -pMySQL@Root2024 -e "SELECT VERSION();"

# 2. 查看兼容性矩阵
# https://dev.mysql.com/doc/refman/8.0/en/upgrading-from-previous-series.html

# 3. 备份数据库
/usr/local/bin/mysql_backup.sh

# 4. 检查兼容性
mysqlcheck --all-databases --check-upgrade

# 5. 禁用MGR自动重启
mysql -uroot -pMySQL@Root2024 -e "
  STOP GROUP_REPLICATION;
"

# 6. 停止ProxySQL监控
mysql -uadmin -padmin -h127.0.0.1 -P6032 -e "
  UPDATE global_variables SET variable_value=0 WHERE variable_name='mysql-monitor_enabled';
  LOAD MYSQL VARIABLES TO RUNTIME;
  SAVE MYSQL VARIABLES TO DISK;
"
```

### 22.2 逐步升级流程

```bash
# 升级顺序: 从库 → 主库

# 1. 升级从库MySQL-03
echo "升级MySQL-03..."
systemctl stop mysqld
yum install -y mysql-community-server-8.0.36
systemctl start mysqld

# 等待从库启动
mysql -uroot -pMySQL@Root2024 -e "SELECT VERSION();"

# 2. 升级从库MySQL-02
echo "升级MySQL-02..."
systemctl stop mysqld
yum install -y mysql-community-server-8.0.36
systemctl start mysqld

# 3. 升级主库MySQL-01
echo "升级MySQL-01..."
# 先将MGR切换到MySQL-02
mysql -uroot -pMySQL@Root2024 -e "
  SET GLOBAL group_replication_force_members = '10.10.30.12:33061,10.10.30.13:33061';
"

# 等待新Primary就绪
mysql -h 10.10.30.12 -uroot -pMySQL@Root2024 -e "
  SELECT MEMBER_ROLE FROM performance_schema.replication_group_members;
"

# 升级MySQL-01
systemctl stop mysqld
yum install -y mysql-community-server-8.0.36
systemctl start mysqld

# 将MySQL-01重新加入集群
mysql -h 10.10.30.11 -uroot -pMySQL@Root2024 -e "
  CHANGE REPLICATION SOURCE TO
    SOURCE_USER='repl_user',
    SOURCE_PASSWORD='Repl@Pass2024',
    SOURCE_AUTO_POSITION=1
  FOR CHANNEL 'group_replication_recovery';
  START GROUP_REPLICATION;
"

# 4. 启用ProxySQL监控
mysql -uadmin -padmin -h127.0.0.1 -P6032 -e "
  UPDATE global_variables SET variable_value=1 WHERE variable_name='mysql-monitor_enabled';
  LOAD MYSQL VARIABLES TO RUNTIME;
  SAVE MYSQL VARIABLES TO DISK;
"
```

### 22.3 升级后验证

```bash
# 1. 验证所有节点版本
mysql -uroot -pMySQL@Root2024 -e "
  SELECT MEMBER_ID, MEMBER_HOST, MEMBER_STATE, MEMBER_ROLE
  FROM performance_schema.replication_group_members;
"

# 2. 验证MGR集群健康
mysql -uroot -pMySQL@Root2024 -e "
  SELECT CHANNEL_NAME, MEMBER_STATE, COUNT_TRANSACTIONS_IN_QUEUE
  FROM performance_schema.replication_group_member_stats;
"

# 3. 验证ProxySQL路由
mysql -uadmin -padmin -h127.0.0.1 -P6032 -e "
  SELECT * FROM stats_mysql_connection_pool;
"

# 4. 验证应用连接
mysql -uapp_user -pAppP@ss2024! -h127.0.0.1 -P6033 -e "SELECT 1"

# 5. 运行压力测试
mysqlslap --user=app_user --password=AppP@ss2024! \
  --host=127.0.0.1 --port=6033 \
  --auto-generate-sql \
  --auto-generate-sql-load-type=read \
  --auto-generate-sql-write-number=1000 \
  --number-of-queries=10000 \
  --concurrency=50 \
  --iterations=3
```

### 22.4 回滚方案

```bash
# 如果升级失败，执行以下回滚步骤:

# 1. 停止新版本MySQL
systemctl stop mysqld

# 2. 恢复旧版本
yum downgrade mysql-community-server-8.0.35

# 3. 恢复数据
systemctl start mysqld

# 4. 从备份恢复
/usr/local/bin/mysql_restore.sh

# 5. 验证集群恢复
mysql -uroot -pMySQL@Root2024 -e "
  SELECT MEMBER_ID, MEMBER_HOST, MEMBER_STATE, MEMBER_ROLE
  FROM performance_schema.replication_group_members;
"
```

---



## 踩坑记录

### Q1: MGR成员频繁RECOVERING
**原因**: 大事务导致flow_control触发
**解决**: 分批执行大事务(每批10000行)

### Q2: ProxySQL读写分离不生效
**原因**: query_rules中的match_pattern未正确匹配
**解决**: 使用SELECT ... FOR UPDATE测试写路由

### Q3: xtrabackup备份失败报"not a valid backup"
**原因**: 备份目录权限不正确
**解决**: 确保备份目录所有者为mysql用户

### Q4: 磁盘满导致MySQL无法写入
**原因**: binlog未自动清理
**解决**: SET GLOBAL expire_logs_days = 7

### Q5: 主从复制延迟超过30秒
**原因**: 从库单线程回放binlog
**解决**: 启用多线程复制(replica_parallel_workers=4)

> 本项目基于25个语雀知识库(2699篇,584万字)编写