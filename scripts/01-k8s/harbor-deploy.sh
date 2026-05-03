#!/bin/bash
# Harbor双节点部署脚本
set -euo pipefail

# Harbor HA需要:
# 1. 外部PostgreSQL(主备同步)
# 2. 外部Redis(主备)
# 3. 共享对象存储(NFS/S3)
# 4. HAProxy负载均衡

HARBOR_VERSION="2.9.0"
HARBOR_HOST="${HARBOR_HOST:?请设置HARBOR_HOST}"
HARBOR_ADMIN_PASSWORD="${HARBOR_ADMIN_PASSWORD:?请设置HARBOR_ADMIN_PASSWORD}"

echo "=== Harbor单实例部署(学习验证用) ==="
echo "⚠️ 生产环境请参考Harbor官方HA文档"

wget https://github.com/goharbor/harbor/releases/download/v${HARBOR_VERSION}/harbor-online-installer-v${HARBOR_VERSION}.tgz
tar xzf harbor-online-installer-v${HARBOR_VERSION}.tgz
cd harbor

cp harbor.yml.tmpl harbor.yml
sed -i "s|hostname: reg.mydomain.com|hostname: ${HARBOR_HOST}|" harbor.yml
sed -i "s|harbor_admin_password: Harbor12345|harbor_admin_password: ${HARBOR_ADMIN_PASSWORD}|" harbor.yml
sed -i "s|  password: root123|  password: \${HARBOR_DB_PASSWORD}|" harbor.yml

echo "⚠️ 请先配置外部数据库和Redis，然后执行: ./install.sh --with-trivy"
echo "⚠️ 本脚本仅用于学习验证，生产环境需配置HA"
