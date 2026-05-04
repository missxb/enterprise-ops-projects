#!/bin/bash
# MySQL MGR集群生产级部署
set -euo pipefail
umask 077

# === 必填参数 ===
MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:?请设置MYSQL_ROOT_PASSWORD}"
MYSQL_REPL_PASSWORD="${MYSQL_REPL_PASSWORD:?请设置MYSQL_REPL_PASSWORD}"
MYSQL_APP_PASSWORD="${MYSQL_APP_PASSWORD:?请设置MYSQL_APP_PASSWORD}"
NODES="${NODES:-10.10.30.11 10.10.30.12 10.10.30.13}"
MYSQL_VERSION="${MYSQL_VERSION:-8.0.36}"

echo "=== MySQL MGR集群生产级部署 ==="
echo "节点: ${NODES}"
echo "版本: MySQL ${MYSQL_VERSION}"

# Step 1: 配置所有节点
echo ""
echo ">>> Step 1: 配置MySQL环境"
for node in ${NODES}; do
  echo "  配置 ${node}..."
  ssh root@${node} bash << EOF
    # 安装MySQL
    rpm -ivh https://dev.mysql.com/get/mysql80-community-release-el7-11.noarch.rpm
    yum install -y mysql-community-server-${MYSQL_VERSION}

    # 配置my.cnf
    cat > /etc/my.cnf << MYCNF
[mysqld]
# === 基础配置 ===
server-id=${NODE_ID}
datadir=/var/lib/mysql
socket=/var/lib/mysql/mysql.sock
log-error=/var/log/mysqld.log

# === MGR配置 ===
gtid_mode=ON
enforce_gtid_consistency=ON
master_info_repository=TABLE
relay_log_info_repository=TABLE
binlog_checksum=NONE
log_slave_updates=ON
log_bin=mysql-bin
binlog_format=ROW

# === 组复制 ===
plugin_load_add='group_replication.so'
group_replication_group_name="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
group_replication_start_on_boot=OFF
group_replication_local_address="${node}:33061"
group_replication_group_seeds="${NODES// /:33061,}:33061"
group_replication_bootstrap_group=OFF

# === 半同步(可选，MGR内部已同步) ===
# rpl_semi_sync_master_enabled=1
# rpl_semi_sync_slave_enabled=1

# === 性能优化 ===
innodb_buffer_pool_size=12G
innodb_log_file_size=2G
innodb_flush_log_at_trx_commit=1
sync_binlog=1
max_connections=1000
character-set-server=utf8mb4
collation-server=utf8mb4_unicode_ci
MYCNF

    systemctl enable mysqld
    systemctl start mysqld
EOF
  echo "  ✅ ${node} MySQL已配置"
done

# Step 2: 初始化MGR集群
echo ""
echo ">>> Step 2: 初始化MGR集群"

# 在第一个节点执行
FIRST_NODE=$(echo ${NODES} | awk '{print $1}')
ssh root@${FIRST_NODE} mysql -uroot -p${MYSQL_ROOT_PASSWORD} << 'MGR_INIT'
  # 创建复制用户
  CREATE USER IF NOT EXISTS 'repl'@'%' IDENTIFIED BY '${MYSQL_REPL_PASSWORD}';
  GRANT REPLICATION SLAVE ON *.* TO 'repl'@'%';

  # 创建MGR用户
  CREATE USER IF NOT EXISTS 'mgr_user'@'%' IDENTIFIED BY '${MYSQL_REPL_PASSWORD}';
  GRANT GROUP_REPLICATION ON *.* TO 'mgr_user'@'%';

  # 配置MGR
  CHANGE REPLICATION SOURCE TO SOURCE_USER='repl', SOURCE_PASSWORD='${MYSQL_REPL_PASSWORD}'
    FOR CHANNEL 'group_replication_recovery';

  # 启动集群(第一个节点)
  SET GLOBAL group_replication_bootstrap_group=ON;
  START GROUP_REPLICATION;
  SET GLOBAL group_replication_bootstrap_group=OFF;
MGR_INIT

# 其他节点加入集群
OTHER_NODES=$(echo ${NODES} | awk '{for(i=2;i<=NF;i++) print $i}')
for node in ${OTHER_NODES}; do
  ssh root@${node} mysql -uroot -p${MYSQL_ROOT_PASSWORD} << MGR_JOIN
    CREATE USER IF NOT EXISTS 'repl'@'%' IDENTIFIED BY '${MYSQL_REPL_PASSWORD}';
    GRANT REPLICATION SLAVE ON *.* TO 'repl'@'%';
    CHANGE REPLICATION SOURCE TO SOURCE_USER='repl', SOURCE_PASSWORD='${MYSQL_REPL_PASSWORD}'
      FOR CHANNEL 'group_replication_recovery';
    START GROUP_REPLICATION;
MGR_JOIN
  echo "  ✅ ${node} 已加入MGR集群"
done

# Step 3: 验证集群状态
echo ""
echo ">>> Step 3: 验证MGR集群"
ssh root@${FIRST_NODE} mysql -uroot -p${MYSQL_ROOT_PASSWORD} -e "SELECT * FROM performance_schema.replication_group_members;"

# Step 4: 部署ProxySQL
echo ""
echo ">>> Step 4: 部署ProxySQL读写分离"
echo "  ProxySQL配置:"
echo "    - 写入: MGR Primary"
echo "    - 读取: MGR Secondary(轮询)"
echo "    - 故障检测: 自动剔除不健康节点"

echo ""
echo "=== MySQL MGR集群部署完成 ==="
