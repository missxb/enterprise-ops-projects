#!/bin/bash
# etcd备份脚本 - 适用于K8s 1.28 (静态Pod模式)
# 前置条件: kubectl可访问集群, /etc/kubernetes/pki/etcd/证书存在
set -euo pipefail
umask 077

BACKUP_DIR="/data/etcd-backup"
DATE=$(date +%Y%m%d_%H%M%S)
KEEP_DAYS=7

mkdir -p ${BACKUP_DIR}

echo "检查etcd健康状态..."
ETCDCTL_API=3 etcdctl endpoint health \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key || { echo "etcd不健康，跳过备份"; exit 1; }

echo "备份etcd..."
ETCDCTL_API=3 etcdctl snapshot save ${BACKUP_DIR}/etcd-snapshot-${DATE}.db \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key

echo "验证快照..."
ETCDCTL_API=3 etcdctl snapshot status ${BACKUP_DIR}/etcd-snapshot-${DATE}.db --write-out=table

echo "清理过期备份..."
find ${BACKUP_DIR} -name "etcd-snapshot-*.db" -mtime +${KEEP_DAYS} -delete

echo "✅ etcd备份完成: etcd-snapshot-${DATE}.db"
