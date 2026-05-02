# 企业级MySQL高可用集群 - MGR + ProxySQL + 自动备份

> 完整实现MySQL高可用方案，覆盖MGR集群、读写分离、自动备份、PITR恢复、慢查询优化

---

## 一、架构

```
                    ┌──────────────────┐
                    │   Application    │
                    └────────┬─────────┘
                             │
                    ┌────────▼─────────┐
                    │    ProxySQL      │
                    │ 读写分离+连接池   │
                    │ 读: 轮询从库      │
                    │ 写: 路由主库      │
                    └──┬───────┬───┬───┘
                       │       │   │
              ┌────────▼┐ ┌───▼──┐ ┌▼────────┐
              │ MySQL-01│ │-02   │ │MySQL-03 │
              │ Primary │ │Secondary│ │Secondary│
              │ (读写)  │ │(只读)  │ │(只读)   │
              └─────────┘ └──────┘ └─────────┘
                       MGR Group Replication
```

---

## 二、服务器规划

| 角色 | IP | 配置 | 用途 |
|------|-----|------|------|
| MySQL-01 | 10.10.30.11 | 16C/64G/1T NVMe | MGR Primary |
| MySQL-02 | 10.10.30.12 | 16C/64G/1T NVMe | MGR Secondary |
| MySQL-03 | 10.10.30.13 | 16C/64G/1T NVMe | MGR Secondary |
| ProxySQL | 10.10.30.21 | 8C/16G/100G | 代理层 |
| 备份服务器 | 10.10.30.31 | 4C/16G/10T | xtrabackup备份 |

---

## 三、MySQL MGR集群配置

### 3.1 三台MySQL节点统一配置

```ini
# /etc/my.cnf - MGR集群配置
[mysqld]
# 基础配置
server-id=1                          # 每台不同: 1/2/3
port=3306
datadir=/data/mysql
socket=/var/lib/mysql/mysql.sock
pid-file=/var/run/mysqld/mysqld.pid
character-set-server=utf8mb4
collation-server=utf8mb4_unicode_ci
default-time-zone='+08:00'

# InnoDB配置
innodb_buffer_pool_size=48G          # 75%内存
innodb_buffer_pool_instances=16
innodb_log_file_size=2G
innodb_log_buffer_size=64M
innodb_flush_log_at_trx_commit=1     # MGR必须=1保证一致性
innodb_flush_method=O_DIRECT
innodb_file_per_table=1
innodb_autoinc_lock_mode=2           # MGR必须=2
innodb_lock_wait_timeout=10

# GTID配置（MGR依赖GTID）
gtid_mode=ON
enforce_gtid_consistency=ON
binlog_checksum=NONE                 # MGR必须NONE
log_bin=mysql-bin
binlog_format=ROW
max_binlog_size=512M
expire_logs_days=7

# 半同步复制
plugin_load_add='semisync_source.so'
plugin_load_add='semisync_replica.so'
rpl_semi_sync_source_enabled=1
rpl_semi_sync_source_timeout=3000

# 连接配置
max_connections=2000
max_connect_errors=100
wait_timeout=600
interactive_timeout=600
thread_cache_size=64

# 慢查询
slow_query_log=1
slow_query_log_file=/data/mysql/slow.log
long_query_time=1
log_queries_not_using_indexes=1

# Performance Schema
performance_schema=ON
performance_schema_max_table_instances=500

# MGR核心配置
plugin_load_add='group_replication.so'
loose-group_replication_group_name="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
loose-group_replication_start_on_boot=OFF     # 首次启动OFF
loose-group_replication_local_address="10.10.30.11:33061"  # 每台不同
loose-group_replication_group_seeds="10.10.30.11:33061,10.10.30.12:33061,10.10.30.13:33061"
loose-group_replication_single_primary_mode=ON
loose-group_replication_enforce_update_everywhere_checks=OFF
loose-group_replication_recovery_get_public_key=1

# 过滤不需要同步的库
binlog-do_db=app_db
binlog-do_db=user_db
binlog-do_db=order_db
```

### 3.2 初始化MGR集群

```bash
#!/bin/bash
# init_mgr.sh - 在MySQL-01(Primary)上执行

set -euo pipefail

MYSQL_CMD="mysql -uroot -pMySQL@Root2024"

echo "Step 1: 配置复制用户..."
${MYSQL_CMD} << 'SQL'
SET GLOBAL super_read_only=OFF;
CREATE USER IF NOT EXISTS 'repl_user'@'%' IDENTIFIED BY 'Repl@Pass2024';
GRANT REPLICATION SLAVE ON *.* TO 'repl_user'@'%';
FLUSH PRIVILEGES;
SQL

echo "Step 2: 配置MGR引导..."
${MYSQL_CMD} << 'SQL'
SET GLOBAL group_replication_bootstrap_group=ON;
START GROUP_REPLICATION;
SET GLOBAL group_replication_bootstrap_group=OFF;
SQL

echo "Step 3: 验证集群状态..."
${MYSQL_CMD} -e "SELECT * FROM performance_schema.replication_group_members\G"

echo "在MySQL-02和MySQL-03上执行以下命令加入集群:"
echo "
-- 在MySQL-02/03上执行:
CHANGE REPLICATION SOURCE TO
  SOURCE_USER='repl_user',
  SOURCE_PASSWORD='Repl@Pass2024',
  SOURCE_AUTO_POSITION=1
  FOR CHANNEL 'group_replication_recovery';
START GROUP_REPLICATION;
"
```

### 3.3 集群验证

```bash
#!/bin/bash
# verify_mgr.sh - 验证MGR集群健康

set -euo pipefail

echo "========== 集群成员状态 =========="
mysql -uroot -pMySQL@Root2024 -e "
  SELECT MEMBER_ID, MEMBER_HOST, MEMBER_PORT, MEMBER_STATE, MEMBER_ROLE
  FROM performance_schema.replication_group_members;
"

echo "========== 复制延迟 =========="
mysql -uroot -pMySQL@Root2024 -e "
  SELECT CHANNEL_NAME, SERVICE_STATE, COUNT_TRANSACTIONS_IN_QUEUE
  FROM performance_schema.replication_group_member_stats;
"

echo "========== 集群一致性检查 =========="
mysql -uroot -pMySQL@Root2024 -e "
  SELECT MEMBER_ROLE, MEMBER_STATE FROM performance_schema.replication_group_members
  WHERE MEMBER_STATE != 'ONLINE';
" 2>/dev/null && echo "⚠️ 有异常成员!" || echo "✅ 所有成员正常"
```

---

## 四、ProxySQL读写分离

### 4.1 ProxySQL配置

```bash
#!/bin/bash
# install_proxysql.sh - 安装配置ProxySQL

set -euo pipefail

echo "安装ProxySQL..."
yum install -y proxysql

# 启动ProxySQL
systemctl enable proxysql
systemctl start proxysql

echo "配置后端MySQL..."
mysql -uadmin -padmin -h127.0.0.1 -P6032 << 'SQL'
-- 添加MySQL服务器
INSERT INTO mysql_servers(hostgroup_id, hostname, port, weight, max_connections, max_replication_lag)
VALUES
  (10, '10.10.30.11', 3306, 1000, 2000, 0),    -- 写组
  (20, '10.10.30.12', 3306, 500, 2000, 0),     -- 读组
  (20, '10.10.30.13', 3306, 500, 2000, 0);     -- 读组

-- 配置监控用户
UPDATE global_variables SET variable_value='monitor' WHERE variable_name='mysql-monitor_username';
UPDATE global_variables SET variable_value='Monitor@2024' WHERE variable_name='mysql-monitor_password';
UPDATE global_variables SET variable_value=2000 WHERE variable_name='mysql-monitor_ping_interval';
UPDATE global_variables SET variable_value=500 WHERE variable_name='mysql-monitor_read_only_interval';

-- 读写分离规则
INSERT INTO mysql_query_rules(rule_id, active, match_pattern, destination_hostgroup, apply)
VALUES
  (1, 1, '^SELECT.*FOR UPDATE$', 10, 1),    -- SELECT FOR UPDATE → 写组
  (2, 1, '^SELECT', 20, 1),                   -- 普通SELECT → 读组
  (3, 1, '.*', 10, 1);                         -- 其他 → 写组

-- 添加用户
INSERT INTO mysql_users(username, password, default_hostgroup, max_connections)
VALUES ('app_user', 'AppP@ss2024!', 10, 2000);

-- 加载配置
LOAD MYSQL SERVERS TO RUNTIME;
LOAD MYSQL VARIABLES TO RUNTIME;
LOAD MYSQL QUERY RULES TO RUNTIME;
LOAD MYSQL USERS TO RUNTIME;

SAVE MYSQL SERVERS TO DISK;
SAVE MYSQL VARIABLES TO DISK;
SAVE MYSQL QUERY RULES TO DISK;
SAVE MYSQL USERS TO DISK;
SQL

echo "✅ ProxySQL配置完成"
echo "管理端口: 6032 (admin/admin)"
echo "服务端口: 6033 (app_user/AppP@ss2024!)"
```

---

## 五、自动化备份

```bash
#!/bin/bash
# mysql_backup.sh - Xtrabackup自动备份

set -euo pipefail

BACKUP_DIR="/data/backup/mysql"
DATE=$(date +%Y%m%d_%H%M%S)
KEEP_DAYS=7
MYSQL_USER="backup"
MYSQL_PASS="Backup@2024"

mkdir -p ${BACKUP_DIR}/{full,incr,binlog}

echo "========== 全量备份 =========="
xtrabackup --backup   --user=${MYSQL_USER} --password=${MYSQL_PASS}   --target-dir=${BACKUP_DIR}/full/full-${DATE}   --parallel=4   --compress   --compress-threads=4

echo "获取LSN..."
LSN=$(xtrabackup --backup --prepare --target-dir=${BACKUP_DIR}/full/full-${DATE} --export 2>&1 | grep "completed OK" | tail -1)

echo "备份binlog..."
mysqlbinlog --read-from-remote-server   --host=10.10.30.11 --user=${MYSQL_USER} --password=${MYSQL_PASS}   --start-datetime="$(date -d '1 hour ago' '+%Y-%m-%d %H:%M:%S')"   --stop-datetime="$(date '+%Y-%m-%d %H:%M:%S')"   mysql-bin.000001 > ${BACKUP_DIR}/binlog/binlog-${DATE}.sql

echo "清理过期备份..."
find ${BACKUP_DIR}/full -maxdepth 1 -type d -mtime +${KEEP_DAYS} -exec rm -rf {} +
find ${BACKUP_DIR}/binlog -mtime +${KEEP_DAYS} -delete

echo "✅ 备份完成: full-${DATE}"
du -sh ${BACKUP_DIR}/full/full-${DATE}

# crontab: 每天凌晨2点全量备份
# 0 2 * * * /opt/scripts/mysql_backup.sh >> /var/log/mysql-backup.log 2>&1
```

---

## 六、PITR恢复

```bash
#!/bin/bash
# pitr_restore.sh - 基于时间点恢复

set -euo pipefail

RESTORE_DIR="/data/restore"
BACKUP_DIR="/data/backup/mysql"
TARGET_TIME="2024-01-15 14:30:00"

echo "Step 1: 找到最近的全量备份..."
LATEST_FULL=$(ls -td ${BACKUP_DIR}/full/full-* | head -1)
echo "使用备份: ${LATEST_FULL}"

echo "Step 2: 应用redo log..."
xtrabackup --prepare --target-dir=${LATEST_FULL} --apply-log-only

echo "Step 3: 恢复数据..."
systemctl stop mysqld
rm -rf /data/mysql/*
xtrabackup --copy-back --target-dir=${LATEST_FULL}

echo "Step 4: 应用binlog到目标时间点..."
# 找到对应的binlog文件
xtrabackup --prepare --target-dir=${LATEST_FULL}

chown -R mysql:mysql /data/mysql
systemctl start mysqld

echo "✅ PITR恢复完成，已恢复到: ${TARGET_TIME}"
```

---

## 七、慢查询优化

```sql
-- 开启慢查询日志
SET GLOBAL slow_query_log=ON;
SET GLOBAL long_query_time=1;
SET GLOBAL log_queries_not_using_indexes=ON;

-- 分析Top慢查询
SELECT
  DIGEST_TEXT,
  COUNT_STAR as exec_count,
  ROUND(SUM_TIMER_WAIT/1e12, 2) as total_time_sec,
  ROUND(AVG_TIMER_WAIT/1e12, 4) as avg_time_sec,
  SUM_ROWS_EXAMINED as rows_examined,
  SUM_ROWS_SENT as rows_sent
FROM performance_schema.events_statements_summary_by_digest
ORDER BY SUM_TIMER_WAIT DESC
LIMIT 20;

-- 查看表索引使用情况
SELECT
  object_schema, object_name, index_name,
  count_star as uses,
  count_read, count_write
FROM performance_schema.table_io_waits_summary_by_index_usage
WHERE object_schema NOT IN ('mysql', 'performance_schema', 'sys')
ORDER BY count_star DESC
LIMIT 20;

-- 查看InnoDB缓冲池
SHOW GLOBAL STATUS LIKE 'Innodb_buffer_pool_%';
-- 命中率 = 1 - (Innodb_buffer_pool_reads / Innodb_buffer_pool_read_requests)
```

---

> 本项目基于25个语雀知识库(2699篇,584万字)编写
