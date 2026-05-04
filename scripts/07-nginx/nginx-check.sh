#!/bin/bash
# Nginx配置测试脚本
set -euo pipefail
umask 077

BACKENDS="${BACKENDS:-10.10.11.21 10.10.11.22 10.10.11.23}"

echo "=== Nginx配置检查 ==="

# 检查配置语法
nginx -t 2>&1 || { echo "❌ 配置语法错误"; exit 1; }

# 检查端口监听
echo "检查80/443端口..."
ss -tlnp | grep -E ':80|:443' || echo "⚠️ 80/443端口未监听"

# 检查SSL证书
echo "检查SSL证书..."
for cert in /etc/nginx/ssl/*.crt; do
  if [ -f "$cert" ]; then
    echo "  证书: $cert"
    openssl x509 -in "$cert" -noout -dates 2>/dev/null || echo "  ❌ 证书无效"
  fi
done

# 检查后端健康
echo "检查后端健康..."
for backend in ${BACKENDS}; do
  curl -s -o /dev/null -w "%{http_code}" http://${backend}:8080/health || echo "  ❌ ${backend} 不可达"
done

echo "✅ Nginx配置检查完成"
