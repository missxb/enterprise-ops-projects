#!/bin/bash
# Harbor双节点部署脚本
set -euo pipefail
umask 077
# 依赖: docker-ce, docker-compose-plugin
# 前置: node-init.sh(节点初始化)
# HA部署: 请使用 scripts/01-k8s/harbor-ha.sh
# 证书管理: 请使用cert-manager自动续期(见脚本末尾说明)

# Harbor HA需要:
# 1. 外部PostgreSQL(主备同步)
# 2. 外部Redis(主备)
# 3. 共享对象存储(NFS/S3)
# 4. HAProxy负载均衡

HARBOR_VERSION="2.12.0"
HARBOR_HOST="${HARBOR_HOST:?请设置HARBOR_HOST}"
HARBOR_ADMIN_PASSWORD="${HARBOR_ADMIN_PASSWORD:?请设置HARBOR_ADMIN_PASSWORD}"
HARBOR_DB_PASSWORD="${HARBOR_DB_PASSWORD:?请设置HARBOR_DB_PASSWORD}"

echo "=== Harbor单实例部署(学习验证用) ==="
echo "⚠️ 生产环境请参考Harbor官方HA文档"

wget https://github.com/goharbor/harbor/releases/download/v${HARBOR_VERSION}/harbor-online-installer-v${HARBOR_VERSION}.tgz
tar xzf harbor-online-installer-v${HARBOR_VERSION}.tgz
cd harbor

cp harbor.yml.tmpl harbor.yml
sed -i "s|hostname: reg.mydomain.com|hostname: ${HARBOR_HOST}|" harbor.yml
sed -i "s|harbor_admin_password: Harbor12345|harbor_admin_password: ${HARBOR_ADMIN_PASSWORD}|" harbor.yml
HARBOR_DB_PASSWORD="${HARBOR_DB_PASSWORD:?请设置HARBOR_DB_PASSWORD}"
sed -i "s|  password: root123|  password: ${HARBOR_DB_PASSWORD}|" harbor.yml

echo "⚠️ 请先配置外部数据库和Redis，然后执行: ./install.sh --with-trivy"
echo "⚠️ 本脚本仅用于学习验证，生产环境需配置HA"

# === 证书自动续期(cert-manager) ===
echo ""
echo "=== 配置cert-manager自动证书续期 ==="
echo "[推荐] 使用cert-manager替代手动openssl生成证书"
echo "安装cert-manager:"
echo "  helm repo add jetstack https://charts.jetstack.io"
echo "  helm install cert-manager jetstack/cert-manager \\"
echo "    --namespace cert-manager --create-namespace \\"
echo "    --set crds.enabled=true"
echo ""
echo "ClusterIssuer示例(Let's Encrypt):"
cat << 'CERT_EOF'
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: admin@your-domain.com
    privateKeySecretRef:
      name: letsencrypt-prod-key
    solvers:
    - http01:
        ingress:
          class: nginx
CERT_EOF
echo ""
echo "[内网环境] 使用自签CA + cert-manager:"
echo "  1. 创建自签CA: openssl req -x509 -nodes -days 3650 ..."
echo "  2. 配置cert-manager CA Issuer"
echo "  3. Harbor ingress注解: cert-manager.io/cluster-issuer: ca-issuer"
echo "  cert-manager会自动在到期前30天续期证书"
