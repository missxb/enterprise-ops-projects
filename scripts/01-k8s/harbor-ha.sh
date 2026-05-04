#!/bin/bash
# Harbor生产级HA部署脚本
# 外部PG + 外部Redis + OSS + 双节点 + 负载均衡
set -euo pipefail
umask 077

# === 必填参数 ===
HARBOR_ADMIN_PASSWORD="${HARBOR_ADMIN_PASSWORD:?请设置HARBOR_ADMIN_PASSWORD}"
HARBOR_DB_PASSWORD="${HARBOR_DB_PASSWORD:?请设置HARBOR_DB_PASSWORD}"
REDIS_PASSWORD="${REDIS_PASSWORD:?请设置REDIS_PASSWORD}"
OSS_ENDPOINT="${OSS_ENDPOINT:?请设置OSS_ENDPOINT(如oss-cn-hangzhou.aliyuncs.com)}"
OSS_BUCKET="${OSS_BUCKET:?请设置OSS_BUCKET}"
HARBOR_HOSTNAME="${HARBOR_HOSTNAME:?请设置HARBOR_HOSTNAME(如harbor.example.com)}"
HARBOR_VERSION="${HARBOR_VERSION:-2.10.1}"

# === 节点列表 ===
MASTER_NODES="${MASTER_NODES:-10.10.10.31}"
BACKUP_NODES="${BACKUP_NODES:-10.10.10.32}"
LOAD_BALANCER="${LOAD_BALANCER:-10.10.10.30}"

echo "=== Harbor生产级HA部署 ==="
echo "版本: ${HARBOR_VERSION}"
echo "主节点: ${MASTER_NODES}"
echo "备节点: ${BACKUP_NODES}"
echo "负载均衡: ${LOAD_BALANCER}"

# Step 1: 部署外部PostgreSQL(使用阿里云RDS或自建)
echo ""
echo ">>> Step 1: 外部PostgreSQL配置"
echo "  [生产建议] 使用阿里云RDS PostgreSQL 14+高可用版"
echo "  [自建方案] 主备流复制 + Patroni自动故障转移"

# 连接数据库并初始化
PG_HOST="${PG_HOST:?请设置PG_HOST}"
PG_PORT="${PG_PORT:-5432}"
PG_ADMIN_USER="${PG_ADMIN_USER:?请设置PG_ADMIN_USER}"
PG_ADMIN_PASS="${PG_ADMIN_PASS:?请设置PG_ADMIN_PASS}"

PGPASS_FILE=$(mktemp)
chmod 600 "${PGPASS_FILE}"
echo "${PG_HOST}:${PG_PORT}:harbor_registry:${PG_ADMIN_USER}:${PG_ADMIN_PASS}" > "${PGPASS_FILE}"

PGPASSWORD="${PG_ADMIN_PASS}" psql -h "${PG_HOST}" -p "${PG_PORT}" -U "${PG_ADMIN_USER}" -d postgres <<-PGEOSQL
  CREATE DATABASE harbor_registry;
  CREATE USER harbor WITH PASSWORD '${HARBOR_DB_PASSWORD}';
  GRANT ALL PRIVILEGES ON DATABASE harbor_registry TO harbor;
  ALTER DATABASE harbor_registry OWNER TO harbor;
PGEOSQL
rm -f "${PGPASS_FILE}"
echo "  ✅ PostgreSQL数据库harbor_registry已创建"

# Step 2: 部署外部Redis(使用阿里云Redis或自建Sentinel)
echo ""
echo ">>> Step 2: 外部Redis配置"
echo "  [生产建议] 使用阿里云Redis 6.0+集群版"
echo "  [自建方案] 3主3从 + Sentinel监控"

# 验证Redis连接
REDIS_HOST="${REDIS_HOST:?请设置REDIS_HOST}"
REDIS_PORT="${REDIS_PORT:-6379}"
redis-cli -h "${REDIS_HOST}" -p "${REDIS_PORT}" -a "${REDIS_PASSWORD}" ping 2>/dev/null | grep -q PING && \
  echo "  ✅ Redis连接正常" || \
  echo "  ⚠️  Redis连接失败，请检查 ${REDIS_HOST}:${REDIS_PORT}"

# Step 3: 配置OSS共享存储
echo ""
echo ">>> Step 3: OSS共享存储配置"
echo "  创建OSS Bucket: ${OSS_BUCKET}"
echo "  Endpoint: ${OSS_ENDPOINT}"
echo "  访问密钥: 通过环境变量或RAM角色授予"

# Step 4: 生成Harbor配置
echo ""
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
    host: rds-xxx.pg.rds.aliyuncs.com
    port: 5432
    username: harbor
    password: ${HARBOR_DB_PASSWORD}
    core_database: registry
    max_idle_conns: 100
    max_open_conns: 900

# === 外部Redis(不使用内置Redis) ===
redis:
  host: r-xxx.redis.rds.aliyuncs.com
  port: 6379
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

# === 数据卷(不使用本地存储) ===
data_volume:
  persistence:
    enabled: false  # 使用OSS，不挂载本地存储

# === 日志(发送到ELK) ===
log:
  level: info
  type: json-file
  path: /var/log/harbor
  rotate:
    max_size: 50m
    max_archives: 10

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
echo ">>> Step 7: 配置负载均衡"
echo "  VIP: ${LOAD_BALANCER}"
echo "  后端: ${MASTER_NODES} + ${BACKUP_NODES}"

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
}

server {
    listen 443 ssl http2;
    server_name ${HARBOR_HOSTNAME};

    ssl_certificate     /opt/harbor/cert/server.crt;
    ssl_certificate_key /opt/harbor/cert/server.key;
    ssl_protocols       TLSv1.2 TLSv1.3;

    location / {
        proxy_pass https://harbor_backend;
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
echo ">>> Step 8: 验证HA"
echo "  1. 访问 https://${HARBOR_HOSTNAME}"
echo "  2. 推送镜像测试: docker push ${HARBOR_HOSTNAME}/library/alpine:latest"
echo "  3. 停止主节点，验证自动切换"
echo "  4. 验证镜像拉取不受影响"

echo ""
echo "=== Harbor HA部署完成 ==="
