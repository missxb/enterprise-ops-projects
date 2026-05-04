#!/bin/bash
# etcd恢复脚本
set -euo pipefail
umask 077

ETCD_ENDPOINT="${ETCD_ENDPOINT:-https://127.0.0.1:2379}"
ETCD_CACERT="${ETCD_CACERT:-/etc/kubernetes/pki/etcd/ca.crt}"
ETCD_CERT="${ETCD_CERT:-/etc/kubernetes/pki/etcd/server.crt}"
ETCD_KEY="${ETCD_KEY:-/etc/kubernetes/pki/etcd/server.key}"
BACKUP_FILE="${1:?用法: $0 <备份文件路径>}"

echo "=== etcd恢复 ==="
echo "⚠️ 警告: 此操作将覆盖当前etcd数据!"

# 确认
read -p "确认恢复? (yes/no): " CONFIRM
[ "$CONFIRM" != "yes" ] && { echo "已取消"; exit 0; }

# 停止kube-apiserver
echo "Step 1: 停止kube-apiserver..."
mv /etc/kubernetes/manifests/kube-apiserver.yaml /tmp/kube-apiserver.yaml.bak 2>/dev/null || true
sleep 5

# 恢复etcd数据
echo "Step 2: 恢复etcd数据..."
ETCDCTL_API=3 etcdctl snapshot restore "$BACKUP_FILE" \
  --data-dir=/var/lib/etcd-restore \
  --name=$(hostname) \
  --initial-cluster="${ETCD_CLUSTER:-etcd-0=https://127.0.0.1:2380}" \
  --initial-advertise-peer-urls="https://127.0.0.1:2380" \
  --initial-cluster-token="etcd-cluster"

# 替换数据目录
echo "Step 3: 替换数据目录..."
rm -rf /var/lib/etcd.bak
mv /var/lib/etcd /var/lib/etcd.bak
mv /var/lib/etcd-restore /var/lib/etcd

# 启动kube-apiserver
echo "Step 4: 启动kube-apiserver..."
mv /tmp/kube-apiserver.yaml.bak /etc/kubernetes/manifests/kube-apiserver.yaml
sleep 10

# 验证
echo "Step 5: 验证..."
ETCDCTL_API=3 etcdctl endpoint health \
  --endpoints=$ETCD_ENDPOINT \
  --cacert=$ETCD_CACERT \
  --cert=$ETCD_CERT \
  --key=$ETCD_KEY

echo "✅ etcd恢复完成"
