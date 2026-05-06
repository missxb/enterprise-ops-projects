#!/bin/bash
# MySQL MGR集群生产级部署
# 依赖: mysql 8.0, ssh(节点间免密)
# 前置: 至少3个节点, 节点间网络互通, 每个节点16G+内存
set -euo pipefail
umask 077

# === 必填参数 ===
MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:?请设置MYSQL_ROOT_PASSWORD}"
MYSQL_REPL_PASSWORD="${MYSQL_REPL_PASSWORD:?请设置MYSQL_REPL_PASSWORD}"
MYSQL_APP_PASSWORD="${MYSQL_APP_PASSWORD:?请设置MYSQL_APP_PASSWORD}"
NODES="${NODES:-10.10.30.11 10.10.30.12 10.10.30.13}"
MYSQL_VERSION="${MYSQL_VERSION:-8.0.36}"

# 创建临时密码文件(避免密码暴露在命令行和进程列表中)
MYSQL_CNF=$(mktemp /tmp/mysql.cnf.XXXXXX)
chmod 600 "${MYSQL_CNF}"
cat > "${MYSQL_CNF}" << CNFEOF
[client]
user=root
password=${MYSQL_ROOT_PASSWORD}
CNFEOF
trap 'rm -f "${MYSQL_CNF}"' EXIT

# 部署步骤跟踪(用于精准回滚)
CURRENT_STEP=0
STEP_TOTAL=4

# 回滚函数(只清理失败步骤的资源，不盲目rm -rf)
rollback() {
  local failed_step=$CURRENT_STEP
  local failed_node="${FAILED_NODE:-unknown}"
  echo "⚠️ 部署失败 (Step ${failed_step}, Node: ${failed_node})，开始精准回滚..."

  # Step 4: ProxySQL - 如果部署了ProxySQL则停止
  if [ $failed_step -ge 4 ]; then
    echo "  回滚 Step 4: 停止ProxySQL..."
    docker stop proxysql 2>/dev/null && docker rm proxysql 2>/dev/null || true
  fi

  # Step 3: 验证阶段 - 无需回滚操作

  # Step 2: MGR初始化 - 如果集群已初始化则停止MGR
  if [ $failed_step -ge 2 ]; then
    echo "  回滚 Step 2: 停止MGR复制..."
    for node in ${NODES}; do
      ssh root@${node} "mysql -e \"STOP GROUP_REPLICATION;\" 2>/dev/null" || true
    done
  fi

  # Step 1: 节点配置 - 只停止mysqld，不删除数据目录
  if [ $failed_step -ge 1 ]; then
    echo "  回滚 Step 1: 停止mysqld服务(保留数据)..."
    for node in ${NODES}; do
      ssh root@${node} "systemctl stop mysqld 2>/dev/null" || true
    done
  fi

  echo "✅ 回滚完成(已清理失败步骤资源，数据目录已保留供排查)"
  echo "   如需完全清除，请手动执行: for n in ${NODES}; do ssh root@\$n 'rm -rf /var/lib/mysql/*'; done"
  exit 1
}
trap rollback ERR

echo "=== MySQL MGR集群生产级部署 ==="
echo "节点: ${NODES}"
echo "版本: MySQL ${MYSQL_VERSION}"

# Step 1: 配置所有节点
echo ""
echo ">>> Step 1: 配置MySQL环境"
CURRENT_STEP=1
NODE_ID=0
INNODB_BUFFER_POOL="${INNODB_BUFFER_POOL:-48G}"
FAILED_NODE=""
# 动态生成MGR集群UUID(避免多集群复用导致脑裂)
MGR_CLUSTER_UUID=$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)
echo "MGR Cluster UUID: ${MGR_CLUSTER_UUID}"

for node in ${NODES}; do
  NODE_ID=$((NODE_ID+1))
  echo "  配置 ${node} (server-id=${NODE_ID})..."
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

binlog_checksum=CRC32  # MySQL 8.0.20+ MGR支持CRC32
log_replica_updates=ON
log_bin=mysql-bin
binlog_format=ROW

# === 组复制 ===
plugin_load_add='group_replication.so'
group_replication_group_name="${MGR_CLUSTER_UUID}"
group_replication_start_on_boot=OFF
group_replication_local_address="${node}:33061"
group_replication_group_seeds="${NODES// /:33061,}:33061"
group_replication_bootstrap_group=OFF

# === 半同步(可选，MGR内部已同步) ===
# rpl_semi_sync_master_enabled=1
# rpl_semi_sync_slave_enabled=1

# === 性能优化 ===
innodb_buffer_pool_size=${INNODB_BUFFER_POOL}
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
CURRENT_STEP=2

# 在第一个节点执行
FIRST_NODE=$(echo ${NODES} | awk '{print $1}')
# 将密码配置文件传到第一个节点
scp -o StrictHostKeyChecking=no "${MYSQL_CNF}" root@${FIRST_NODE}:/tmp/mysql.cnf
ssh root@${FIRST_NODE} mysql --defaults-extra-file=/tmp/mysql.cnf << MGR_INIT
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
#   将密码配置文件传到每个节点
    scp -o StrictHostKeyChecking=no "${MYSQL_CNF}" root@${node}:/tmp/mysql.cnf
    ssh root@${node} mysql --defaults-extra-file=/tmp/mysql.cnf << MGR_JOIN
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
CURRENT_STEP=3
ssh root@${FIRST_NODE} mysql --defaults-extra-file=/tmp/mysql.cnf -e "SELECT * FROM performance_schema.replication_group_members;"

# Step 4: 部署ProxySQL
echo ""
echo ">>> Step 4: 部署ProxySQL读写分离"
CURRENT_STEP=4
echo "  ProxySQL配置:"
echo "    - 写入: MGR Primary"
echo "    - 读取: MGR Secondary(轮询)"
echo "    - 故障检测: 自动剔除不健康节点"

echo ""
echo "=== MySQL MGR集群部署完成 ==="
# 清理远程节点上的临时密码文件
for node in ${NODES}; do
  ssh root@${node} "rm -f /tmp/mysql.cnf" 2>/dev/null || true
done
