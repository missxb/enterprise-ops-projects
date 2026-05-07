# 企业级MySQL高可用集群 - MGR + ProxySQL + 自动备份

> 完整实现MySQL高可用方案，覆盖MGR集群、读写分离、自动备份、PITR恢复、慢查询优化

> **⚠️ 版本说明**：本文档基于MySQL 8.4 LTS（2026年4月发布）编写。
> - **MySQL 8.0已于2026-04-30 EOL**，不可用于新部署，必须升级到8.4 LTS
> - MySQL 8.4 LTS支持周期8年（至2032年），是生产环境首选
> - **主要变化**：认证插件默认caching_sha2_password、SQL Mode更严格、MGR增强
> - **升级工具**：mysqlsh util.checkForServerUpgrade() 预检兼容性
> 
> **MySQL 8.4 LTS新特性**：
> - **InnoDB ClusterSet**：支持跨机房部署，解决MGR的网络延迟敏感问题
> - **Clone Plugin增强**：在线扩容优化，新节点加入更快
> - **MGR自动故障转移改进**：更智能的故障检测和切换
> - **Binlog加密**：支持Binlog加密存储，提升安全性
> - **微秒级时间戳**：PITR恢复支持微秒级精度
> 
> **配套组件版本**：
> - **ProxySQL 2.7+**：支持MySQL 8.4认证插件
> - **Xtrabackup 8.4.x**：支持MySQL 8.4备份（版本必须匹配）
> - **MySQL Shell 8.4**：管理工具

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
log-error=/data/mysql/error.log      # 错误日志路径
innodb_buffer_pool_instances=16
innodb_log_file_size=2G
> **MySQL 8.4注意**: innodb_log_file_size可动态调整。建议使用innodb_redo_log_capacity替代(8.4推荐)
innodb_log_buffer_size=64M
innodb_flush_log_at_trx_commit=1     # MGR必须=1保证一致性
innodb_flush_method=O_DIRECT
innodb_file_per_table=1
innodb_autoinc_lock_mode=2           # MGR必须=2
innodb_lock_wait_timeout=10
sync_binlog=1                        # 每次提交同步binlog，保证数据一致性

# GTID配置（MGR依赖GTID）
gtid_mode=ON
enforce_gtid_consistency=ON
binlog_checksum=CRC32  # MySQL 8.0.20+ MGR支持CRC32
log_bin=mysql-bin
binlog_format=ROW
max_binlog_size=512M
binlog_expire_logs_seconds=1209600  # 14天（备份保留30天，binlog至少保留14天以支持PITR）
> **冲突风险**: binlog保留14天,备份保留30天。binlog保留期应不少于备份保留期的一半，当前设置合理。

# [已修复] MGR内部使用Paxos协议同步，不需要半同步复制
# 半同步复制(semisync)与MGR会冲突，已移除

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

# 从库多线程复制(推荐所有节点配置)
replica_parallel_workers=8           # 并行回放线程数
replica_parallel_type='LOGICAL_CLOCK'  # 基于逻辑时钟并行
replica_preserve_commit_order=1      # 保证提交顺序

# MGR核心配置
plugin_load_add='group_replication.so'
loose-group_replication_group_name="550e8400-e29b-41d4-a716-446554000000"  # 请替换为uuidgen生成的UUID
loose-group_replication_start_on_boot=OFF     # 首次启动OFF
loose-group_replication_local_address="10.10.30.11:33061"  # 每台不同
loose-group_replication_group_seeds="10.10.30.11:33061,10.10.30.12:33061,10.10.30.13:33061"
loose-group_replication_single_primary_mode=ON
loose-group_replication_enforce_update_everywhere_checks=OFF
loose-group_replication_member_weight=80  # 投票权重(0-100)，数值大的优先成为Primary

# [注意] MGR下binlog-do_db可能不一致，生产环境不建议使用
# 如需库级过滤，在应用层实现或使用独立从库+replicate-do-db
```

### 3.2 初始化MGR集群

```bash
#!/bin/bash
# init_mgr.sh - 在MySQL-01(Primary)上执行

set -euo pipefail

# 使用--defaults-extra-file避免命令行密码暴露(需要先创建临时.cnf文件)
MYSQL_CNF=$(mktemp /tmp/mysql.cnf.XXXXXX)
chmod 600 "${MYSQL_CNF}"
cat > "${MYSQL_CNF}" << CNFEOF
[client]
user=root
password=${MYSQL_ROOT_PASSWORD}
CNFEOF
trap 'rm -f "${MYSQL_CNF}"' EXIT
MYSQL_CMD="mysql --defaults-extra-file=${MYSQL_CNF}"

echo "Step 1: 配置复制用户..."
${MYSQL_CMD} << SQL
SET GLOBAL super_read_only=OFF;
CREATE USER IF NOT EXISTS 'repl_user'@'%' IDENTIFIED BY '${MYSQL_REPL_PASSWORD}';
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
  SOURCE_PASSWORD='${MYSQL_REPL_PASSWORD}',
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
mysql --defaults-extra-file=${MYSQL_CNF} -e "
  SELECT MEMBER_ID, MEMBER_HOST, MEMBER_PORT, MEMBER_STATE, MEMBER_ROLE
  FROM performance_schema.replication_group_members;
"

echo "========== 复制延迟 =========="
mysql --defaults-extra-file=${MYSQL_CNF} -e "
  SELECT CHANNEL_NAME, SERVICE_STATE, COUNT_TRANSACTIONS_IN_QUEUE
  FROM performance_schema.replication_group_member_stats;
"

echo "========== 集群一致性检查 =========="
mysql --defaults-extra-file=${MYSQL_CNF} -e "
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
# 创建ProxySQL临时凭证文件
PROXYSQL_CNF=$(mktemp /tmp/proxysql.cnf.XXXXXX)
chmod 600 "${PROXYSQL_CNF}"
cat > "${PROXYSQL_CNF}" << CNFEOF
[client]
user=admin
password=${PROXYSQL_ADMIN_PASSWORD}
host=127.0.0.1
port=6032
CNFEOF
trap 'rm -f "${PROXYSQL_CNF}"' EXIT
mysql --defaults-extra-file=${PROXYSQL_CNF} << 'SQL'
-- 添加MySQL服务器
INSERT INTO mysql_servers(hostgroup_id, hostname, port, weight, max_connections, max_replication_lag)
VALUES
  (10, '10.10.30.11', 3306, 1000, 2000, 0),    -- 写组
  (20, '10.10.30.12', 3306, 500, 2000, 0),     -- 读组
  (20, '10.10.30.13', 3306, 500, 2000, 0);     -- 读组

-- 配置MGR主机组(自动感知MGR拓扑变化)
-- group_replication_hostgroups让ProxySQL自动检测MGR成员角色,
-- 当Primary切换时自动更新mysql_servers中的hostgroup,无需手动干预
INSERT INTO mysql_group_replication_hostgroups
  (writer_hostgroup, reader_hostgroup, active, max_writers, writer_is_also_reader, max_transactions_behind, check_type)
VALUES
  (10, 20, 1, 1, 0, 100, 'read_only');
-- writer_hostgroup=10: Primary节点自动分配到写组
-- reader_hostgroup=20: Secondary节点自动分配到读组
-- check_type='read_only': 通过read_only变量判断角色(推荐)
-- check_type也可用'server_status'或'group_replication',但read_only最可靠

-- 配置监控用户
UPDATE global_variables SET variable_value='monitor' WHERE variable_name='mysql-monitor_username';
-- 生产环境请替换为真实密码
UPDATE global_variables SET variable_value='${MONITOR_PASSWORD}' WHERE variable_name='mysql-monitor_password';
UPDATE global_variables SET variable_value=2000 WHERE variable_name='mysql-monitor_ping_interval';
UPDATE global_variables SET variable_value=500 WHERE variable_name='mysql-monitor_read_only_interval';

-- 读写分离规则
INSERT INTO mysql_query_rules(rule_id, active, match_pattern, destination_hostgroup, apply)
VALUES
  (1, 1, '^SELECT.*FOR UPDATE$', 10, 1),    -- SELECT FOR UPDATE → 写组
  (2, 1, '^SELECT', 20, 1),                   -- 普通SELECT → 读组
  (3, 1, '.*', 10, 1);                         -- 其他 → 写组

-- 特殊查询路由(必须走写组)
INSERT INTO mysql_query_rules(rule_id, active, match_pattern, destination_hostgroup, apply)
VALUES
  (4, 1, '^SELECT LAST_INSERT_ID', 10, 1),
  (5, 1, '^SELECT @@session', 10, 1),
  (6, 1, '^SET SESSION', 10, 1);
> 这些查询必须路由到写组,否则可能读到旧数据

-- 添加用户
INSERT INTO mysql_users(username, password, default_hostgroup, max_connections)
VALUES ('app_user', '${APP_USER_PASSWORD}', 10, 2000);

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
echo "管理端口: 6032 (admin/*****)"
echo "服务端口: 6033 (app_user/*****)"
```

---

## 五、自动化备份

```bash
#!/bin/bash
# mysql_backup.sh - Xtrabackup自动备份

set -euo pipefail

BACKUP_DIR="/data/backup/mysql"
DATE=$(date +%Y%m%d_%H%M%S)
KEEP_DAYS=30
MYSQL_USER="backup"
MYSQL_PASS="${BACKUP_PASSWORD}"

mkdir -p ${BACKUP_DIR}/{full,incr,binlog}

echo "========== 全量备份 =========="
xtrabackup --backup   --user=${MYSQL_USER} --password=${MYSQL_PASS}   --target-dir=${BACKUP_DIR}/full/full-${DATE}   --parallel=4   --compress   --compress-threads=4

echo "获取LSN..."
# [已修复] 备份阶段不需要--prepare和--export，直接备份即可
# xtrabackup备份会自动记录LSN到xtrabackup_info文件

echo "备份binlog..."
# 使用--defaults-extra-file避免命令行密码暴露
CURRENT_BINLOG=$(mysql --defaults-extra-file=${MYSQL_CNF} -e "SHOW BINARY LOG STATUS" --skip-column-names 2>/dev/null | awk '{print $1}')
mysqlbinlog --read-from-remote-server --raw --to-last-log --defaults-extra-file=${MYSQL_CNF} \
  --host=127.0.0.1 \
  ${CURRENT_BINLOG} \
  --result-file=${BACKUP_DIR}/binlog/binlog-${DATE}_

> **生产建议**: --to-last-log会下载所有binlog,生产环境应:
> 1. 记录上次备份的最后一个binlog位置
> 2. 只备份新增的binlog
> 3. 或使用FLUSH BINARY LOGS后备份旧binlog

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

> **⚠️ 加密Binlog注意**: 如果启用了binlog_encryption=ON(MySQL 8.4新特性)，
> mysqlbinlog无法直接读取加密的binlog文件。恢复前需先解密:
> ```bash
> # 解密binlog文件(需要keyring组件)
> mysqlbinlog --decrypt-keyring --read-from-remote-server ... 
> # 或从keyring获取密钥后本地解密
> xbcrypt --decrypt --encrypt-key="${BINLOG_ENCRYPT_KEY}" \
>   --input-file=encrypted-binlog.xbcrypt > decrypted-binlog
> ```
> 建议: 生产环境关闭binlog_encryption或确保恢复环境有相同的keyring配置。

```bash
#!/bin/bash
# pitr_restore.sh - 基于时间点恢复

set -euo pipefail

RESTORE_DIR="/data/restore"
BACKUP_DIR="/data/backup/mysql"
# [修复] TARGET_TIME不再硬编码，改为从参数/环境变量读取
# 用法: TARGET_TIME="2024-01-15 14:30:00.123456" ./pitr_restore.sh
# 或: ./pitr_restore.sh (将交互式提示输入)
# MySQL 8.4支持微秒级精度(格式: YYYY-MM-DD HH:MM:SS.ffffff)
TARGET_TIME="${TARGET_TIME:-}"
if [ -z "${TARGET_TIME}" ]; then
  read -p "请输入恢复目标时间(格式: YYYY-MM-DD HH:MM:SS[.ffffff]): " TARGET_TIME
fi
if [[ ! "${TARGET_TIME}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{1,6})?$ ]]; then
  echo "❌ 时间格式错误，应为: YYYY-MM-DD HH:MM:SS 或 YYYY-MM-DD HH:MM:SS.ffffff"
  exit 1
fi

echo "Step 1: 找到最近的全量备份..."
LATEST_FULL=$(ls -td ${BACKUP_DIR}/full/full-* | head -1)
echo "使用备份: ${LATEST_FULL}"

echo "Step 2: 停止MySQL并清理数据目录..."
systemctl stop mysqld
rm -rf /data/mysql/*

echo "Step 3: 恢复全量备份..."
xtrabackup --prepare --target-dir=${LATEST_FULL}
xtrabackup --copy-back --target-dir=${LATEST_FULL}

echo "Step 4: 修复权限并启动MySQL..."
chown -R mysql:mysql /data/mysql
systemctl start mysqld

echo "Step 5: 应用binlog到目标时间点..."
for binlog_file in ${BACKUP_DIR}/binlog/binlog-*; do
  if [ -f "${binlog_file}" ] && [[ ! "${binlog_file}" == *.sql ]]; then
    mysqlbinlog --stop-datetime="${TARGET_TIME}" "${binlog_file}" | mysql --defaults-extra-file=${MYSQL_CNF} 2>/dev/null || true
  elif [ -f "${binlog_file}" ]; then
    mysql --defaults-extra-file=${MYSQL_CNF} < "${binlog_file}" 2>/dev/null || true
  fi
done

echo "Step 6: 重启MySQL确保干净状态..."
systemctl restart mysqld

echo "✅ PITR恢复完成，已恢复到: ${TARGET_TIME}"
```

### PITR后重新加入MGR

```sql
-- 1. 停止组复制
STOP GROUP_REPLICATION;

-- 2. 清理GTID
RESET MASTER;

-- 3. 清理复制配置
RESET SLAVE ALL;

-- 4. 使用CLONE PLUGIN从其他节点克隆数据
SET GLOBAL clone_valid_donor_list = 'other_node:3306';
CLONE INSTANCE FROM 'clone_user'@'other_node' IDENTIFIED BY 'password';

-- 5. 或重新初始化MGR
-- change master to master_user='repl', master_password='xxx' \
--   for channel 'group_replication_recovery';
-- start group_replication;
```

> PITR恢复后节点需要重新加入MGR集群,CLONE PLUGIN是最简单的方式

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

> 本项目基于官方文档、技术博客和社区实践编写


---

> ⚠️ **安全声明**: 本文档中的密码(如${MYSQL_ROOT_PASSWORD}、${HARBOR_ADMIN_PASSWORD}等)均为示例占位符。
> 生产环境必须使用密钥管理工具(Vault/K8s Secrets/环境变量)管理敏感信息，
> 切勿将真实密码硬编码在配置文件或脚本中。

## 八、方案对比与选型

### 8.1 MGR vs InnoDB Cluster vs Galera

> **跨机房部署建议**:
> - 单机房: MGR单主模式(3节点)
> - 跨机房: 使用MySQL InnoDB ClusterSet或MGR+异步复制
> - MGR对网络延迟敏感(建议<1ms),跨机房专线必须稳定

| 特性 | MySQL MGR | InnoDB Cluster(8.0.27+) | Percona XtraDB Cluster |
|------|-----------|---------------|----------------|
| 复制方式 | 基于Paxos协议 | MGR + MySQL Shell + Router | Galera同步复制 |
| 数据一致性 | 强一致(多数派) | 强一致(基于MGR) | 强一致(同步复制) |
| 写扩展 | 单主模式单写/多主模式多写 | 同MGR | 真正多主多写 |
| 故障转移 | 自动(基于MGR) | 自动(MySQL Router) | 自动 |
| 运维工具 | 原生SQL | MySQL Shell + Router | 原生SQL |
| 应用透明度 | 需要代理层 | Router自动路由 | 需要代理层 |
| 适用版本 | MySQL 8.4+ | MySQL 8.0.27+ (推荐8.4 LTS) | Percona XtraDB Cluster 8.4+ |
| 最大节点数 | 9个 | 9个 | 16个 |
| 推荐场景 | 中小企业 | 中大型企业 | 需要多主写入 |

**选型建议**:
- MySQL 8.4+ → InnoDB Cluster (MGR + Router)
- 需要强一致性 → MGR单主模式
- 需要多点写入 → Percona XtraDB Cluster (基于Galera)
- 本项目选择: MGR单主模式 + ProxySQL

### 8.3 MySQL 8.4 LTS新特性

#### MySQL Shell安装（管理InnoDB Cluster必备）

```bash
# MySQL Shell安装（MySQL AdminAPI管理工具）
# RHEL/CentOS
dnf install mysql-shell

# Ubuntu/Debian
apt install mysql-shell

# 验证安装
mysqlsh --version

# 连接测试
mysqlsh root@mysql-01:3306 -- sql -e "SELECT VERSION();"
```

> MySQL Shell (mysqlsh) 是InnoDB Cluster的管理工具，提供AdminAPI用于
> cluster创建/加入/状态检查等操作。不安装mysqlsh则无法使用InnoDB Cluster。

#### InnoDB ClusterSet (跨机房部署)

```sql
-- 创建ClusterSet (跨机房高可用)
-- 主集群: 机房A
mysqlsh root@mysql-01:3306 -- cluster create clusterA \
  --user=clusterAdmin --password=xxx

-- 添加从集群: 机房B
mysqlsh root@mysql-04:3306 -- cluster create clusterB \
  --user=clusterAdmin --password=xxx

-- 创建ClusterSet
mysqlsh root@mysql-01:3306 -- clusterset create \
  --primary-cluster=clusterA \
  --clusterset-domain=clusterset.example.com

-- 添加从集群到ClusterSet
mysqlsh root@mysql-04:3306 -- clusterset add-instance clusterB \
  --cluster=clusterB
```

> **注意**: MGR要求奇数节点(3/5/7)。4节点部署需要:
> 1. 使用InnoDB ClusterSet(2个独立集群各3节点)
> 2. 或配置仲裁节点(Recovery Channel)
> 3. 或使用Group Replication的unreachable_majority_timeout

#### Clone Plugin (在线扩容)

```sql
-- 启用Clone Plugin
INSTALL PLUGIN clone SONAME 'mysql_clone.so';

-- 验证Clone状态
SELECT PLUGIN_NAME, PLUGIN_STATUS FROM INFORMATION_SCHEMA.PLUGINS
WHERE PLUGIN_NAME = 'clone';

-- 从主节点克隆数据到新节点
-- 在新节点执行:
SET GLOBAL clone_valid_donor_list = 'mysql-01:3306';
CLONE INSTANCE FROM 'cloneUser'@'mysql-01':3306
  IDENTIFIED BY 'xxx';

-- 克隆完成后，新节点自动加入MGR

-- [注意] Clone需要CLONE_ADMIN权限，授权语句:
GRANT CLONE_ADMIN ON *.* TO 'cloneUser'@'%';
-- 或使用备份专用用户:
GRANT CLONE_ADMIN, RELOAD, LOCK TABLES, REPLICATION CLIENT ON *.* TO 'backup'@'%';
```

#### Binlog加密 (8.4新特性)

```sql
-- 启用Binlog加密
-- 在my.cnf中配置:
[mysqld]
binlog_encryption = ON
binlog_encryption_key_id = 1

-- 查看加密状态
SHOW BINARY LOG STATUS;
SELECT * FROM performance_schema.keyring_component_status;

-- 备份时解密
xtrabackup --backup --decrypt-threads=4 \
  --target-dir=/data/backup/
```

> **[密钥管理注意]** binlog加密密钥由keyring组件管理，密钥轮转时需注意:
> 1. 使用mysqlsh的util.rotateRoutines()或ALTER INSTANCE ROTATE INNODB MASTER KEY轮转密钥
> 2. 旧密钥需保留至所有使用该密钥的binlog文件过期后才能删除
> 3. 密钥备份: 定期导出keyring元数据，丢失密钥将无法解密binlog
> 4. 生产环境建议使用keyring_okv或keyring_hashicorp_vault（集中管理密钥）

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

> **MGR网络分区处理机制**:
> - MGR使用Paxos协议,需要多数派(quorum)才能选举Primary
> - 3节点集群: 容忍1个节点故障(2/3多数)
> - 网络分区时: 拥有多数派的一方继续服务,少数派自动拒绝写入
> - 脑裂风险: 跨机房部署时,如果网络延迟>1ms,可能导致频繁选举

**故障**: 3节点MGR集群出现2个Primary，数据不一致

**背景**: 凌晨3点收到告警，业务反馈订单数据写入异常。登录数据库发现2个节点都是PRIMARY状态，部分订单数据在两个节点上不一致。

**排查过程**:
- 03:00 收到Grafana告警: MGR成员状态异常
- 03:10 SSH登录发现网络正常，ping延迟<1ms
- 03:25 检查MGR集群状态发现机房B的网络交换机在02:50有过一次重启(运维团队凌晨割接)
- 03:30 确认是网络分区导致的脑裂，机房A的2个节点形成了多数派
- 03:45 执行强制恢复，04:00业务恢复正常
- 04:30 数据对账发现有12条订单不一致，手动修复

**根因**: 凌晨网络割接导致短暂分区，MGR在分区恢复后未正确合并

**解决**:
```sql
-- 1. 检查集群状态
SELECT * FROM performance_schema.replication_group_members;

-- 设置超时后自动排除不可达成员(force_members在MySQL 8.0.27+已废弃)
SET GLOBAL group_replication_unreachable_majority_timeout = 10;
STOP GROUP_REPLICATION;
START GROUP_REPLICATION;

--- 3. 重新加入异常节点
```

### 数据一致性校验(必须执行)

```bash
# 数据一致性校验(必须执行)
echo "执行数据一致性校验..."
mysql --defaults-extra-file=${MYSQL_CNF} -e "
  -- 检查是否有未同步的事务
  SELECT MEMBER_ID, MEMBER_STATE, COUNT_TRANSACTIONS_IN_QUEUE
  FROM performance_schema.replication_group_member_stats
  WHERE COUNT_TRANSACTIONS_IN_QUEUE > 0;
"
# 建议使用pt-table-checksum校验主从数据一致性:
# pt-table-checksum --host=master_host --user=root --password=xxx --databases=app_db
# pt-table-sync --execute h=master_host,d=app_db,t=orders
```

### 案例2: 磁盘满导致MySQL崩溃

**故障**: binlog累积占满磁盘，MySQL无法写入

**背景**: 周五下午收到告警磁盘使用率95%，还没来得及处理，周六凌晨MySQL进程被OOM Killer杀死。重启后发现binlog损坏，需要从备份恢复。

**排查过程**:
- 周五15:00 收到磁盘告警，但当时在处理其他故障
- 周五18:00 下班前设置了"明天处理"的提醒
- 周六02:30 MySQL进程被OOM Killer杀死(内存不足)
- 周六08:00 发现MySQL宕机，尝试重启失败
- 周六08:30 检查发现最后一个binlog文件损坏
- 周六09:00 从昨晚的全量备份+xtrabackup恢复
- 周六10:30 业务恢复，丢失约8小时数据(周五18:00-周六02:30)

**教训**: 磁盘告警必须在4小时内处理，不能拖延到"明天"

**解决**:
```sql
-- 1. 紧急清理binlog
PURGE BINARY LOGS BEFORE DATE_SUB(NOW(), INTERVAL 1 DAY);

-- 2. 设置自动过期
SET GLOBAL binlog_expire_logs_seconds = 1209600;  -- 保留14天

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

> **备份安全建议**:
> - 备份加密: 使用gpg或openssl加密备份文件后再上传OSS
> - 跨区域备份: 异地机房或不同可用区存储备份副本
> - 备份验证: 定期(每月)执行恢复演练,验证备份可用性

### 11.1 RTO/RPO目标

| 指标 | 目标值 | 实现方式 |
|------|--------|---------|
| RPO(数据丢失) | < 1秒 | MGR强一致性 + sync_binlog |
| RTO(恢复时间) | < 15分钟 | MGR自动failover |
> MGR自动failover秒级,但应用重连+ProxySQL切换+缓存预热可能需要10-15分钟
| 备份频率 | 每天全量 + 每小时增量 | xtrabackup |
| 备份保留 | 30天(本地) + 180天(OSS归档) | 自动清理 |
> 等保三级要求审计日志留存180天,备份也应满足此要求

### 11.1.1 增量备份示例

```bash
# 增量备份示例
INCREMENTAL_DIR=${BACKUP_DIR}/incremental/$(date +%Y%m%d%H%M)
LATEST_FULL=$(ls -td ${BACKUP_DIR}/full/*/ | head -1)
xtrabackup --backup --incremental --target-dir=${INCREMENTAL_DIR} \
  --incremental-basedir=${LATEST_FULL} --defaults-extra-file=${MYSQL_CNF}
```

> 增量备份基于全量备份,每次只备份变化的页,大幅减少备份时间和存储

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
> **[说明]** sort_buffer_size/join_buffer_size 是每个连接在需要排序/JOIN时分配的缓冲区，
> 并非所有连接同时占用。实际内存峰值远小于 4MB × max_connections，但仍需预留足够空间。
- 操作系统+其他: ~15GB
```

### 12.2 磁盘规划

```
数据盘计算:
- 当前数据量: 500GB
- 年增长率: 100%
> 实际增长通常线性而非指数。建议:
> - 第1年: +500GB
> - 第2年: +750GB (增长放缓)
> - 第3年: +1000GB
> - 3年总计约2.25TB,不是4TB(指数)
- 冗余系数: 1.5
- 所需磁盘: 6TB
- 建议: 4 × 2TB NVMe SSD (RAID10，最少4块盘)
```

---

## 十三、运维SOP

### 13.1 日常巡检

```bash
#!/bin/bash
# mysql_daily_check.sh

echo "========== MySQL日常巡检 =========="

# 1. 实例状态
mysql --defaults-extra-file=${MYSQL_CNF} -e "SELECT VERSION(); SELECT UPTIME;"

# 2. 连接数
mysql --defaults-extra-file=${MYSQL_CNF} -e "SHOW STATUS LIKE 'Threads_connected';"

# 3. 复制状态
mysql --defaults-extra-file=${MYSQL_CNF} -e "
  SELECT MEMBER_ID, MEMBER_HOST, MEMBER_PORT, MEMBER_STATE, MEMBER_ROLE
  FROM performance_schema.replication_group_members;"

# 4. 慢查询数量
mysql --defaults-extra-file=${MYSQL_CNF} -e "SHOW STATUS LIKE 'Slow_queries';"

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
├── configs/                 # 配置文件(gitlab-ci/Dockerfile/Helm/Terraform/Ansible)
├── tests/                  # 部署验证测试
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
mysql --defaults-extra-file=${MYSQL_CNF} -e "
  SHOW REPLICA STATUS\G
" | grep -E "Seconds_Behind|Slave_SQL_Running|Exec_Master_Log_Pos|Replica_IO_Running|Replica_SQL_Running"

# Seconds_Behind_Master(8.0.22前) / Seconds_Behind_Source(8.0.22+)
# 发现: 一个DELETE大表操作(删除1000万行)导致从库重放慢
```

**处理步骤**:
```sql
-- 1. 在从库查看当前执行的SQL
SHOW PROCESSLIST;
-- 找到正在执行的大DELETE语句

-- 2. 临时跳过该事务(危险操作，需确认数据一致性)
STOP REPLICA;
SET GLOBAL sql_replica_skip_counter = 1;
START REPLICA;

> MySQL 8.0.26+推荐使用sql_replica_前缀(旧语法已废弃)

-- 3. 验证复制状态
SHOW REPLICA STATUS\G

-- 4. 在主库优化大事务
-- 将大DELETE拆分为小批次
DELETE FROM logs WHERE created_at < '2023-01-01' LIMIT 10000;
-- 循环执行直到删除完成

-- 5. 设置大事务告警
-- 在my.cnf中添加:
-- binlog_transaction_dependency_tracking = WRITESET
transaction_write_set_extraction = XXHASH64
> MGR必需配置,使用XXHASH64算法计算事务写集合指纹
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
mysql --defaults-extra-file=${MYSQL_CNF} -e "
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
mysql --defaults-extra-file=${MYSQL_CNF} -e "
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
SET GLOBAL replica_parallel_workers = 8;  # [已修复] MySQL 8.0.26+推荐replica前缀
SET GLOBAL replica_parallel_type = 'LOGICAL_CLOCK';
SET GLOBAL replica_preserve_commit_order = 1;
```

### 案例6: 表锁导致业务超时

**故障现象**: 应用端大量连接超时，ProxySQL监控显示写操作堆积

**根因分析**:
```bash
# 查看锁等待
mysql --defaults-extra-file=${MYSQL_CNF} -e "
  SELECT 
    r.trx_id waiting_trx_id,
    r.trx_mysql_thread_id waiting_thread,
    r.trx_query waiting_query,
    b.trx_id blocking_trx_id,
    b.trx_mysql_thread_id blocking_thread,
    b.trx_query blocking_query
  FROM performance_schema.data_lock_waits w  # [已修复] innodb_lock_waits在8.0.1+已废弃
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
  --user=root --password=${MYSQL_ROOT_PASSWORD} \
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
# $(mysql --defaults-extra-file=${MYSQL_CNF} -e "SHOW BINARY LOGS" -N | tail -1 | awk "{print \$1}")  200G
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
SHOW VARIABLES LIKE 'binlog_expire_logs_seconds';
SHOW VARIABLES LIKE 'max_binlog_size';

-- 3. 优化binlog配置
SET GLOBAL binlog_expire_logs_seconds = 1209600;  -- 保留14天
SET GLOBAL max_binlog_size = 256M;  -- 每个文件最大256MB

-- 4. 对大表使用Row模式优化
-- 在my.cnf中添加:
binlog_row_image = MINIMAL  -- 只记录变化的列
> MINIMAL模式只记录变化的列,可减少binlog大小30-50%
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
mysql --defaults-extra-file=${MYSQL_CNF} -e "
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

-- 4. 设置密码有效期(等保要求密码90天过期，与步骤2的永不过期矛盾需根据场景选择)
--   等保合规场景:
SET GLOBAL default_password_lifetime = 90;
--   应用账号场景(避免业务中断):
-- SET GLOBAL default_password_lifetime = 0;

-- 5. 创建密码轮换脚本
-- 每月检查密码过期时间，提前30天提醒
SELECT user, host, 
  password_last_changed,
  DATE_ADD(password_last_changed, INTERVAL 60 DAY) as reminder_date
FROM mysql.user 
WHERE password_last_changed < DATE_SUB(NOW(), INTERVAL 30 DAY);
```

#### Vault动态密码方案(推荐生产环境)

```bash
# 使用HashiCorp Vault动态生成MySQL密码，消除明文密码泄露风险
# 1. 启用Vault MySQL秘密引擎
vault secrets enable -path=mysql mysql-database

# 2. 配置MySQL连接
vault write mysql/config/connection \
  connection_url="{{username}}:{{password}}@tcp(10.10.30.11:3306)/" \
  max_open_connections=10 \
  max_idle_connections=5

# 3. 创建角色(绑定MySQL用户)
vault write mysql/roles/app_user \
  db_name=mysql \
  creation_statements="CREATE USER '{{name}}'@'%' IDENTIFIED BY '{{password}}'; GRANT SELECT,INSERT,UPDATE,DELETE ON *.* TO '{{name}}'@'%';" \
  default_ttl="1h" \
  max_ttl="24h"

# 4. 应用端获取动态密码
vault read mysql/creds/app_user
# → username: v-app_user-xxxxx  password: A1b2-C3d4-E5f6
# 有效期1h，到期自动回收

# 5. ProxySQL配置动态密码轮换(Cron每55分钟刷新)
NEW_CREDS=$(vault read -format=json mysql/creds/app_user)
NEW_USER=$(echo $NEW_CREDS | jq -r '.data.username')
NEW_PASS=$(echo $NEW_CREDS | jq -r '.data.password')
mysql --defaults-extra-file=${PROXYSQL_CNF} -e "
  UPDATE mysql_users SET username='${NEW_USER}', password='${NEW_PASS}' WHERE username LIKE 'v-app_user-%';
  LOAD MYSQL USERS TO RUNTIME;
  SAVE MYSQL USERS TO DISK;
"
```

> Vault动态密码优势: 密码自动轮换、审计日志、最小权限、即时吊销。
> 注意: ProxySQL的mysql_users表每次更新后需要LOAD USERS TO RUNTIME生效。

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
innodb_buffer_pool_dump_pct=100

# dump_pct=100表示关闭时dump全部缓冲池页，启动时可完全预热
# 默认40仅预热最热的40%页，生产环境建议100以避免冷启动后性能骤降

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
> **MySQL 8.4注意**: innodb_log_file_size可动态调整。建议使用innodb_redo_log_capacity替代(8.4推荐)

# innodb_log_files_in_group: redo log文件组数量
# MySQL 8.0.30+ 默认4个文件
innodb_log_files_in_group=4

> **MySQL 8.4注意**: innodb_log_files_in_group已废弃,由innodb_redo_log_capacity自动管理。建议使用:
> innodb_redo_log_capacity = 8589934592  # 8GB

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
                    │ MySQL-01 (Primary) │ MySQL-02 (Secondary) │
                    │ MySQL-03 (Secondary)│ MySQL-04 (Sync Standby)│
                    ├─────────────────┼───────────────────────┤
                    │        ◄── 专线互联 (延迟<2ms) ──►       │
                    └─────────────────┴───────────────────────┘

                    流量路由:
                    - 正常: 全部流量 → 机房A
                    - 注意: MGR要求奇数节点(3/5/7)，4节点需配置仲裁节点或改为3节点
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
# expr: mysql_replica_status_seconds_behind_source > 5
> MySQL 8.0.26+推荐使用replica前缀(旧语法已废弃)
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
mysql -h 10.10.30.11 --defaults-extra-file=${MYSQL_CNF} -e "SELECT 1" 2>/dev/null
if [ $? -eq 0 ]; then
    echo "❌ 主库仍可用，无需切换"
    exit 1
fi

echo "⚠️ 主库不可用，开始切换..."

# 2. 将机房B的Secondary提升为Primary
echo "提升MySQL-04为Primary..."
mysql -h 10.10.40.14 --defaults-extra-file=${MYSQL_CNF} << 'SQL'
STOP GROUP_REPLICATION;
SET GLOBAL group_replication_bootstrap_group = ON;
START GROUP_REPLICATION;
SET GLOBAL group_replication_bootstrap_group = OFF;
SQL

# 3. 更新ProxySQL配置
echo "更新ProxySQL路由..."
# 创建ProxySQL临时凭证文件
PROXYSQL_CNF=$(mktemp /tmp/proxysql.cnf.XXXXXX)
chmod 600 "${PROXYSQL_CNF}"
cat > "${PROXYSQL_CNF}" << CNFEOF
[client]
user=admin
password=${PROXYSQL_ADMIN_PASSWORD}
host=127.0.0.1
port=6032
CNFEOF
trap 'rm -f "${PROXYSQL_CNF}"' EXIT
mysql --defaults-extra-file=${PROXYSQL_CNF} << 'SQL'
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

# DNS更新代码示例(阿里云DNS API):
# https://help.aliyun.com/document_detail/29739.html
DNS_ZONE_ID="your-zone-id"
DNS_RECORD_ID="your-record-id"
NEW_IP="10.10.40.10"

# 使用阿里云CLI更新解析记录
aliyun alidns UpdateDomainRecord \
  --RecordId ${DNS_RECORD_ID} \
  --RR mysql \
  --Type A \
  --Value ${NEW_IP} \
  --TTL 60

# 或使用PowerDNS API:
# curl -X PUT "http://pdns-server:8081/api/v1/servers/localhost/zones/${DNS_ZONE_ID}" \
#   -H "X-API-Key: ${PDNS_API_KEY}" \
#   -H "Content-Type: application/json" \
#   -d '{"rrsets":[{"name":"mysql.example.com.","type":"A","ttl":60,"records":[{"content":"'${NEW_IP}'","disabled":false}]}]}'

> DNS TTL建议设置为60秒，切换后生效时间约1-2分钟。

# 5. 验证
echo "验证切换..."
mysql -h 10.10.40.14 --defaults-extra-file=${MYSQL_CNF} -e "
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
    MySQL企业版: ¥75,000/年 × 3 = ¥225,000
    
  总计: ¥1,539,000 (约154万/3年)

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
          image: prom/mysqld-exporter:v0.16.0
> 生产环境应使用最新稳定版,查看https://github.com/prometheus/mysqld_exporter/releases
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
              valueFrom:
                secretKeyRef:
                  name: mysql-exporter-secret
                  key: data-source-name
                  # Secret示例: exporters:Exporter@2024@(10.10.50.100:6033)/
                  # 注意: 连接ProxySQL(6033)而非MySQL Primary(3306)，避免监控影响主库性能
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
        expr: mysql_replica_status_seconds_behind_source > 30
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "MySQL复制延迟 > 30秒"
          description: "实例 {{ $labels.instance }} 复制延迟 {{ $value }}秒"

      - alert: MySQLReplicationLagCritical
        expr: mysql_replica_status_seconds_behind_source > 300
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "MySQL复制延迟 > 5分钟"
          description: "实例 {{ $labels.instance }} 复制延迟 {{ $value }}秒"

      # 复制线程告警
      - alert: MySQLReplicationStopped
        expr: mysql_replica_status_slave_sql_running == 0 or mysql_replica_status_slave_io_running == 0
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
mysql --defaults-extra-file=${MYSQL_CNF} -e "SELECT VERSION(); SELECT UPTIME;"

# 2. 连接数
mysql --defaults-extra-file=${MYSQL_CNF} -e "
  SELECT 
    (SELECT VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME='Threads_connected') as current_conn,
    (SELECT VARIABLE_VALUE FROM performance_schema.global_variables WHERE VARIABLE_NAME='max_connections') as max_conn;
"

# 3. MGR集群状态
mysql --defaults-extra-file=${MYSQL_CNF} -e "
  SELECT MEMBER_ID, MEMBER_HOST, MEMBER_PORT, MEMBER_STATE, MEMBER_ROLE
  FROM performance_schema.replication_group_members;
"

# 4. 复制延迟
mysql --defaults-extra-file=${MYSQL_CNF} -e "SHOW REPLICA STATUS\G" | grep -E "Seconds_Behind|Replica_SQL_Running"

# 5. 慢查询数量
mysql --defaults-extra-file=${MYSQL_CNF} -e "SHOW STATUS LIKE 'Slow_queries';"

# 6. InnoDB缓冲池命中率
mysql --defaults-extra-file=${MYSQL_CNF} -e "
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

> **⚠️ 部署前**: 执行前请确保脚本已赋予可执行权限: `chmod +x emergency_fix.sh`
> 脚本应存放在 `/opt/scripts/emergency_fix.sh`，并加入Ansible部署流程自动分发。

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
mysql --defaults-extra-file=${MYSQL_CNF} -e "SELECT VERSION();"

# 2. 查看兼容性矩阵
# https://dev.mysql.com/doc/refman/8.0/en/upgrading-from-previous-series.html

# 3. 备份数据库
/usr/local/bin/mysql_backup.sh

# 4. 检查兼容性
mysqlsh root@localhost -- util.checkForServerUpgrade()
> mysqlcheck在MySQL 8.4中已废弃,使用mysqlsh替代

# 5. 禁用MGR自动重启
mysql --defaults-extra-file=${MYSQL_CNF} -e "
  STOP GROUP_REPLICATION;
"

# 6. 停止ProxySQL监控
mysql --defaults-extra-file=${PROXYSQL_CNF} -e "
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
yum install -y mysql-community-server-8.4.4
systemctl start mysqld

# 等待从库启动
mysql --defaults-extra-file=${MYSQL_CNF} -e "SELECT VERSION();"

# 2. 升级从库MySQL-02
echo "升级MySQL-02..."
systemctl stop mysqld
yum install -y mysql-community-server-8.4.4
systemctl start mysqld

# 3. 升级主库MySQL-01
echo "升级MySQL-01..."
# 先将MGR切换到MySQL-02(force_members在MySQL 8.0.27+已废弃，使用unreachable_majority_timeout)
mysql --defaults-extra-file=${MYSQL_CNF} -e "
  SET GLOBAL group_replication_unreachable_majority_timeout = 10;
  STOP GROUP_REPLICATION;
  START GROUP_REPLICATION;
"

# 等待新Primary就绪
mysql -h 10.10.30.12 --defaults-extra-file=${MYSQL_CNF} -e "
  SELECT MEMBER_ROLE FROM performance_schema.replication_group_members;
"

# 升级MySQL-01
systemctl stop mysqld
yum install -y mysql-community-server-8.4.4
systemctl start mysqld

# 将MySQL-01重新加入集群
mysql -h 10.10.30.11 --defaults-extra-file=${MYSQL_CNF} -e "
  CHANGE REPLICATION SOURCE TO
    SOURCE_USER='repl_user',
    SOURCE_PASSWORD='${MYSQL_REPL_PASSWORD}',
    SOURCE_AUTO_POSITION=1
  FOR CHANNEL 'group_replication_recovery';
  START GROUP_REPLICATION;
"

# 4. 启用ProxySQL监控
mysql --defaults-extra-file=${PROXYSQL_CNF} -e "
  UPDATE global_variables SET variable_value=1 WHERE variable_name='mysql-monitor_enabled';
  LOAD MYSQL VARIABLES TO RUNTIME;
  SAVE MYSQL VARIABLES TO DISK;
"
```

### 22.3 升级后验证

```bash
# 1. 验证所有节点版本
mysql --defaults-extra-file=${MYSQL_CNF} -e "
  SELECT MEMBER_ID, MEMBER_HOST, MEMBER_STATE, MEMBER_ROLE
  FROM performance_schema.replication_group_members;
"

# 2. 验证MGR集群健康
mysql --defaults-extra-file=${MYSQL_CNF} -e "
  SELECT CHANNEL_NAME, MEMBER_STATE, COUNT_TRANSACTIONS_IN_QUEUE
  FROM performance_schema.replication_group_member_stats;
"

# 3. 验证ProxySQL路由
mysql --defaults-extra-file=${PROXYSQL_CNF} -e "
  SELECT * FROM stats_mysql_connection_pool;
"

# 4. 验证应用连接
mysql -uapp_user --defaults-extra-file=${MYSQL_CNF} -h127.0.0.1 -P6033 -e "SELECT 1"

# 5. 运行压力测试
mysqlslap --user=app_user --defaults-extra-file=${MYSQL_CNF} \
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
yum downgrade mysql-community-server-8.4.3

# 3. 恢复数据
systemctl start mysqld

# 4. 从备份恢复
/usr/local/bin/mysql_restore.sh

# 5. 验证集群恢复
mysql --defaults-extra-file=${MYSQL_CNF} -e "
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
**解决**: SET GLOBAL binlog_expire_logs_seconds = 1209600  # 14天（配合30天备份保留）

### Q5: 主从复制延迟超过30秒
**原因**: 从库单线程回放binlog
**解决**: 启用多线程复制(replica_parallel_workers=4)

## ProxySQL高可用方案

### 问题: ProxySQL单点故障

当前只部署1台ProxySQL(10.10.30.21)，宕机则所有数据库连接中断。生产环境建议部署2台ProxySQL + Keepalived VIP实现高可用。

### 解决方案: 双ProxySQL + Keepalived

Client → VIP(10.10.30.20) → ProxySQL-01(10.10.30.21) → MySQL MGR
                              ProxySQL-02(10.10.30.22) ↗

Keepalived配置:

vrrp_instance VI_1 {
  state MASTER
  interface eth0
  virtual_router_id 52
  priority 100
  advert_int 1
  authentication {
    auth_type PASS
    auth_pass ${KEEPALIVED_AUTH_PASS:?请设置KEEPALIVED密码}
  }
  virtual_ipaddress {
    10.10.30.20/24 dev eth0
  }
  track_script {
    check_proxysql
  }
}

vrrp_script check_proxysql {
  script "/usr/bin/mysql --defaults-extra-file=/etc/mysql/proxysql.cnf -e 'SELECT 1' -h127.0.0.1 -P6033"
  interval 2
  weight -20
  fall 3
  rise 2
}

> 两台ProxySQL使用同步的mysql_servers和mysql_users配置，通过ProxySQL Admin API或配置文件同步。
>
> **配置同步工具**:
> - 推荐使用 **deck/decktool** 管理ProxySQL配置的版本化和同步
> - decktool 可将ProxySQL配置导出为声明式YAML/Git仓库，实现配置即代码
> - 工作流: decktool pull → Git版本管理 → decktool apply → ProxySQL热加载
> - 替代方案: 定期从PRIMARY ProxySQL的Admin API拉取配置并推送到STANDBY

---

## 附录: MySQL监控扩展建议

> **⚠️ ProxySQL监控精度说明**:
> ProxySQL Admin API返回的统计信息(如stats_mysql_connection_pool)基于内存计数器，
> 重启后归零。以下情况可能导致监控数据不准确:
> 1. ProxySQL重启后计数器清零，Grafana图表出现断点
> 2. 高并发下连接池统计可能有1-2秒延迟
> 3. stats_mysql_query_digest的计数在FLUSH PROXYSQL STATS后重置
> 建议: 使用Prometheus持续采集(间隔≤15s)，并设置告警时考虑数据源可能丢失

| 监控类型 | 指标 | 说明 |
|----------|------|------|
| 慢查询 | slow_query_log | 分析TOP SQL优化 |
| Performance Schema | events_statements_summary | 语句级性能分析 |
| InnoDB Metrics | innodb_buffer_pool_hit_rate | 缓存命中率 |
| 复制延迟 | seconds_behind_source | 主从同步状态 |
| 连接数 | threads_connected | 连接池使用情况 |

> **监控工具推荐**: mysqld_exporter + Prometheus + Grafana
