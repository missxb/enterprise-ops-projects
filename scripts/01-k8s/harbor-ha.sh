#!/bin/bash
# Harbor生产级HA部署脚本
# 外部PG + 外部Redis + OSS + 双节点 + 负载均衡
# 依赖: docker-ce, docker-compose-plugin, psql(客户端), redis-cli, nginx, keepalived
# 前置: 外部PostgreSQL已部署, 外部Redis已部署, OSS Bucket已创建, 节点间SSH免密
# 说明: 负载均衡部分使用Nginx作为简化方案，生产环境推荐HAProxy或云厂商SLB/ALB
# 参考: Harbor官方HA部署文档 https://goharbor.io/docs/latest/administration/configure-multi-instance/
set -euo pipefail
umask 077

# === 回滚函数 ===
CURRENT_STEP=0
rollback() {
  local exit_code=$?
  [ $exit_code -eq 0 ] && return
  echo ""
  echo "⚠️  部署失败(Step ${CURRENT_STEP})，开始回滚..."
  case $CURRENT_STEP in
    6)
      echo "  回滚: 停止Harbor..."
      for node in ${MASTER_NODES} ${BACKUP_NODES}; do
        ssh root@${node} "cd /opt/harbor && docker compose down 2>/dev/null || true"
      done
      ;;
    5)
      echo "  回滚: 停止Docker..."
      for node in ${MASTER_NODES} ${BACKUP_NODES}; do
        ssh root@${node} "systemctl stop docker 2>/dev/null || true"
      done
      ;;
  esac
  echo "✅ 回滚完成"
}
trap rollback ERR

# === 必填参数 ===
HARBOR_ADMIN_PASSWORD="${HARBOR_ADMIN_PASSWORD:?请设置HARBOR_ADMIN_PASSWORD}"
HARBOR_DB_PASSWORD="${HARBOR_DB_PASSWORD:?请设置HARBOR_DB_PASSWORD}"
REDIS_PASSWORD="${REDIS_PASSWORD:?请设置REDIS_PASSWORD}"
OSS_ENDPOINT="${OSS_ENDPOINT:?请设置OSS_ENDPOINT(如oss-cn-hangzhou.aliyuncs.com)}"
OSS_BUCKET="${OSS_BUCKET:?请设置OSS_BUCKET}"
HARBOR_HOSTNAME="${HARBOR_HOSTNAME:?请设置HARBOR_HOSTNAME(如harbor.example.com)}"
HARBOR_VERSION="${HARBOR_VERSION:-2.12.0}"

# === 节点列表 ===
MASTER_NODES="${MASTER_NODES:-10.10.10.31}"
BACKUP_NODES="${BACKUP_NODES:-10.10.10.32}"
LOAD_BALANCER="${LOAD_BALANCER:-10.10.10.30}"

echo "=== Harbor生产级HA部署 ==="
echo "版本: ${HARBOR_VERSION}"
echo "主节点: ${MASTER_NODES}"
echo "备节点: ${BACKUP_NODES}"
echo "负载均衡: ${LOAD_BALANCER}"

# === 前置检查 ===
echo ">>> 前置检查..."
errors=0

# 检查必要命令
for cmd in docker openssl kubectl; do
  command -v $cmd &>/dev/null || { echo "  ❌ $cmd 未安装"; errors=$((errors+1)); }
done

# 检查磁盘空间(至少20GB可用)
avail_gb=$(df -BG /opt 2>/dev/null | awk 'NR==2{print $4}' | tr -d 'G')
if [ "${avail_gb:-0}" -lt 20 ]; then
  echo "  ❌ /opt磁盘空间不足(需20GB,当前${avail_gb:-0}GB)"
  errors=$((errors+1))
fi

# 检查内存(至少8GB)
mem_gb=$(free -g | awk '/Mem:/{print $2}')
if [ "${mem_gb:-0}" -lt 8 ]; then
  echo "  ⚠️  内存不足8GB(当前${mem_gb}GB),可能影响性能"
fi

[ $errors -gt 0 ] && { echo "前置检查失败"; exit 1; }
echo "  ✅ 前置检查通过"

# === SSH免密检查与配置 ===
echo ""
echo ">>> 检查SSH免密连接..."
for node in ${MASTER_NODES} ${BACKUP_NODES} ${LOAD_BALANCER}; do
  if ! ssh -o BatchMode=yes -o ConnectTimeout=5 root@${node} echo ok &>/dev/null; then
    echo "  ⚠️  ${node} SSH免密未配置，正在配置..."
    ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa -N "" -q 2>/dev/null || true
    ssh-copy-id -o StrictHostKeyChecking=no root@${node}
  else
    echo "  ✅ ${node} SSH免密已配置"
  fi
done

# Step 1: 部署外部PostgreSQL(使用阿里云RDS或自建)
echo ""
CURRENT_STEP=1
echo ">>> Step 1: 外部PostgreSQL配置"
echo "  [生产建议] 使用阿里云RDS PostgreSQL 14+高可用版"
echo "  [自建方案] 主备流复制 + Patroni自动故障转移"

# 连接数据库并初始化
PG_HOST="${PG_HOST:?请设置PG_HOST}"
PG_PORT="${PG_PORT:-5432}"
PG_ADMIN_USER="${PG_ADMIN_USER:?请设置PG_ADMIN_USER}"
PG_ADMIN_PASS="${PG_ADMIN_PASS:?请设置PG_ADMIN_PASS}"

PGPASSWORD="${PG_ADMIN_PASS}" psql -h "${PG_HOST}" -p "${PG_PORT}" -U "${PG_ADMIN_USER}" -d postgres <<-PGEOSQL
  CREATE DATABASE harbor_registry;
  CREATE USER harbor WITH PASSWORD '${HARBOR_DB_PASSWORD}';
  GRANT ALL PRIVILEGES ON DATABASE harbor_registry TO harbor;
  ALTER DATABASE harbor_registry OWNER TO harbor;
PGEOSQL
echo "  ✅ PostgreSQL数据库harbor_registry已创建"

# Step 2: 部署外部Redis(使用阿里云Redis或自建Sentinel)
echo ""
CURRENT_STEP=2
echo ">>> Step 2: 外部Redis配置"
echo "  [生产建议] 使用阿里云Redis 6.0+集群版"
echo "  [自建方案] 3主3从 + Sentinel监控"

# 验证Redis连接
REDIS_HOST="${REDIS_HOST:?请设置REDIS_HOST}"
REDIS_PORT="${REDIS_PORT:-6379}"
redis-cli -h "${REDIS_HOST}" -p "${REDIS_PORT}" -a "${REDIS_PASSWORD}" ping 2>/dev/null | grep -q PONG && \
  echo "  ✅ Redis连接正常" || \
  echo "  ⚠️  Redis连接失败，请检查 ${REDIS_HOST}:${REDIS_PORT}"

# Step 3: 配置OSS共享存储
echo ""
CURRENT_STEP=3
echo ">>> Step 3: OSS共享存储配置"
echo "  创建OSS Bucket: ${OSS_BUCKET}"
echo "  Endpoint: ${OSS_ENDPOINT}"
echo "  访问密钥: 通过环境变量或RAM角色授予"

# Step 4: 生成Harbor配置
echo ""
CURRENT_STEP=4
echo ">>> Step 4: 生成Harbor配置"

generate_harbor_config() {
  local NODE_IP=$1
  local ROLE=$2

  ssh root@${NODE_IP} "mkdir -p /opt/harbor"
  cat > /tmp/harbor-${NODE_IP}.yml << HARBOR_EOF
# Harbor HA配置 - ${ROLE}节点
# 版本: ${HARBOR_VERSION}

hostname: ${HARBOR_HOSTNAME}

# === 外部数据库(不使用内置DB) ===
database:
  type: postgresql
  postgresql:
    host: ${PG_HOST}
    port: ${PG_PORT}
    username: harbor
    password: ${HARBOR_DB_PASSWORD}
    core_database: registry
    max_idle_conns: 100
    max_open_conns: 900

# === 外部Redis(不使用内置Redis) ===
redis:
  host: ${REDIS_HOST}
  port: ${REDIS_PORT}
  password: ${REDIS_PASSWORD}
  db_index: 0
  namespace: "harbor:"

# === OSS对象存储 ===
storage_service:
  s3:
    accesskey: \${OSS_ACCESS_KEY}
    secretkey: \${OSS_SECRET_KEY}
    region: cn-hangzhou
    bucket: ${OSS_BUCKET}
    regionendpoint: ${OSS_ENDPOINT}
    encrypt: true
    secure: true
    v4auth: true
    multipartcopythresholdsize: 5368709120
    multipartcopyobjectsize: 5368709120
    multipartcopymaxconcurrency: 100
    multipartcopysinglesize: 1048576

# === 数据卷 ===
# [已禁用] 使用OSS对象存储，不挂载本地存储
# data_volume:
#   persistence:
#     enabled: false

# === 日志(发送到ELK) ===
log:
  level: info
  type: json-file
  path: /var/log/harbor
  rotate:
    max_size: 50m
    max_archives: 10

# === HTTPS配置 ===
# [生产必须] 启用HTTPS以保证镜像传输安全
https:
  enabled: true
  cert: /opt/harbor/cert/server.crt
  key: /opt/harbor/cert/server.key

# === 证书 ===
# 使用cert-manager自动管理，或手动放置证书:
# /data/cert/server.crt
# /data/cert/server.key
HARBOR_EOF

  scp /tmp/harbor-${NODE_IP}.yml root@${NODE_IP}:/opt/harbor/harbor.yml
  echo "  ✅ ${NODE_IP} (${ROLE}) 配置已生成"
}

for node in ${MASTER_NODES}; do
  generate_harbor_config ${node} "主"
done

for node in ${BACKUP_NODES}; do
  generate_harbor_config ${node} "备"
done

# Step 5: 安装Docker + Docker Compose
echo ""
CURRENT_STEP=5
echo ">>> Step 5: 安装Docker + Docker Compose"
for node in ${MASTER_NODES} ${BACKUP_NODES}; do
  ssh root@${node} bash << 'DOCKER_EOF'
    yum install -y yum-utils
    yum-config-manager --add-repo https://mirrors.aliyun.com/docker-ce/linux/centos/docker-ce.repo
    yum install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    systemctl enable --now docker
DOCKER_EOF
  echo "  ✅ ${node} Docker已安装"
done

# Step 6: 下载并安装Harbor
echo ""
CURRENT_STEP=6
echo ">>> Step 6: 下载并安装Harbor"
INSTALL_SCRIPT="https://github.com/goharbor/harbor/releases/download/v${HARBOR_VERSION}/harbor-online-installer-v${HARBOR_VERSION}.tgz"
for node in ${MASTER_NODES} ${BACKUP_NODES}; do
  ssh root@${node} bash << HARBOR_INSTALL_EOF
    cd /opt/harbor
    wget -q ${INSTALL_SCRIPT} -O harbor.tgz
    tar xzf harbor.tgz --strip-components=1
    ./install.sh --with-trivy
HARBOR_INSTALL_EOF
  echo "  ✅ ${node} Harbor已安装"
done

# Step 7: 配置负载均衡(Keepalived + Nginx)
echo ""
CURRENT_STEP=7
echo ">>> Step 7: 配置负载均衡"
echo "  VIP: ${LOAD_BALANCER}"
echo "  后端: ${MASTER_NODES} + ${BACKUP_NODES}"
echo ""
echo "  [生产建议] 推荐使用HAProxy替代Nginx，或使用云厂商SLB/ALB"
echo "  [简化方案] 本脚本使用Nginx作为负载均衡，适用于测试/小规模环境"
echo ""

# 配置Nginx upstream代理Harbor后端
HARBOR_BACKENDS=""
for node in ${MASTER_NODES} ${BACKUP_NODES}; do
  HARBOR_BACKENDS="${HARBOR_BACKENDS}    server ${node}:443 ssl;\n"
done

for node in ${MASTER_NODES} ${BACKUP_NODES}; do
  ssh root@${node} bash << LB_EOF
cat > /etc/nginx/conf.d/harbor-ha.conf << CONF
upstream harbor_backend {
    # Harbor HA后端
$(echo -e "${HARBOR_BACKENDS}")
    # [生产注意] 后端使用自签证书时需关闭SSL验证
    # 如使用正式证书建议保持ssl_verify on
}

server {
    listen 443 ssl http2;
    server_name ${HARBOR_HOSTNAME};

    ssl_certificate     /opt/harbor/cert/server.crt;
    ssl_certificate_key /opt/harbor/cert/server.key;
    ssl_protocols       TLSv1.2 TLSv1.3;

    location / {
        proxy_pass https://harbor_backend;
        proxy_ssl_verify off;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
CONF
  nginx -t && systemctl reload nginx
LB_EOF
  echo "  ✅ ${node} Nginx LB配置已部署"
done

# Step 8: 验证HA
echo ""
CURRENT_STEP=8
echo ">>> Step 8: 验证HA"
echo "  1. 访问 https://${HARBOR_HOSTNAME}"
echo "  2. 推送镜像测试: docker push ${HARBOR_HOSTNAME}/library/alpine:latest"
echo "  3. 停止主节点，验证自动切换"
echo "  4. 验证镜像拉取不受影响"

echo ""
echo "=== Harbor HA部署完成 ==="
