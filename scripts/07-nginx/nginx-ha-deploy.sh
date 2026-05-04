#!/bin/bash
# Nginx+Keepalived生产级高可用部署
set -euo pipefail
umask 077

# === 必填参数 ===
VIP="${VIP:?请设置VIP(如10.10.50.100)}"
NODES="${NODES:-10.10.50.11 10.10.50.12}"
BACKENDS="${BACKENDS:?请设置后端应用服务器列表(空格分隔)}"
AUTH_PASS="${AUTH_PASS:-CHANGEME}"
KEEPALIVED_PASS="${KEEPALIVED_PASS:?请设置KEEPALIVED密码(≤8字符)}"

echo "=== Nginx+Keepalived生产级高可用部署 ==="
echo "VIP: ${VIP}"
echo "节点: ${NODES}"
echo "后端: ${BACKENDS}"

# Step 1: 安装Nginx
echo ""
echo ">>> Step 1: 安装Nginx"
for node in ${NODES}; do
  ssh root@${node} bash << EOF
    yum install -y nginx
    systemctl enable nginx
EOF
  echo "  ✅ ${node} Nginx已安装"
done

# Step 2: 生成Nginx配置
echo ""
echo ">>> Step 2: 生成Nginx负载均衡配置"

# 生成upstream配置(使用printf确保换行正确)
UPSTREAM_CONF=$(printf "upstream app_backend {\n")
for backend in ${BACKENDS}; do
  UPSTREAM_CONF+=$(printf "    server %s:8080 weight=5;\n" "$backend")
done
UPSTREAM_CONF+=$(printf "}")

# 部署配置到所有节点
for node in ${NODES}; do
  ssh root@${node} bash << NGINX_EOF
cat > /etc/nginx/conf.d/app.conf << CONF
# === Nginx生产级负载均衡配置 ===

\${UPSTREAM_CONF}

# === 限流配置 ===
limit_req_zone \$binary_remote_addr zone=api:10m rate=10r/s;
limit_conn_zone \$binary_remote_addr zone=conn:10m;

server {
    listen 80;
    server_name _;

    # === SSL(生产环境启用) ===
    # listen 443 ssl http2;
    # ssl_certificate /etc/nginx/ssl/server.crt;
    # ssl_certificate_key /etc/nginx/ssl/server.key;
    # ssl_protocols TLSv1.2 TLSv1.3;
    # ssl_ciphers HIGH:!aNULL:!MD5;

    # === 请求限制 ===
    location /api/ {
        limit_req zone=api burst=20 nodelay;
        limit_conn conn 100;
        proxy_pass http://app_backend;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_connect_timeout 5s;
        proxy_read_timeout 60s;
        proxy_send_timeout 60s;
    }

    # === 健康检查 ===
    location /health {
        access_log off;
        return 200 "OK";
    }

    # === 默认代理 ===
    location / {
        proxy_pass http://app_backend;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
}
CONF

# 验证配置
nginx -t && systemctl reload nginx
NGINX_EOF
  echo "  ✅ ${node} Nginx配置已部署"
done

# Step 3: 安装Keepalived
echo ""
echo ">>> Step 3: 安装Keepalived(主备模式)"
NODE_ARRAY=(${NODES})
for i in "${!NODE_ARRAY[@]}"; do
  node=${NODE_ARRAY[$i]}
  if [ $i -eq 0 ]; then
    ROLE="MASTER"
    PRIORITY=100
  else
    ROLE="BACKUP"
    PRIORITY=90
  fi

  ssh root@${node} bash << KEEPALIVED_EOF
yum install -y keepalived

cat > /etc/keepalived/keepalived.conf << 'CONF'
global_defs {
    router_id ${node}
}

vrrp_script check_nginx {
    script "/usr/bin/curl -s -o /dev/null http://localhost/health"
    interval 2
    weight -20
    fall 3
    rise 2
}

vrrp_instance VI_1 {
    state ${ROLE}
    interface eth0
    virtual_router_id 51
    priority ${PRIORITY}
    advert_int 1

    authentication {
        auth_type PASS
        auth_pass ${KEEPALIVED_PASS}
    }

    virtual_ipaddress {
        ${VIP}/24 dev eth0
    }

    track_script {
        check_nginx
    }
}
CONF

systemctl enable keepalived
systemctl start keepalived
KEEPALIVED_EOF
  echo "  ✅ ${node} Keepalived已部署(${ROLE})"
done

# Step 4: 验证HA
echo ""
echo ">>> Step 4: 验证HA"
echo "  1. 访问 http://${VIP} 验证流量分发"
echo "  2. 停止主节点Nginx，验证VIP漂移到备节点"
echo "  3. 检查Keepalived日志: journalctl -u keepalived"

echo ""
echo "=== Nginx HA部署完成 ==="
