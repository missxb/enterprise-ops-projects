#!/bin/bash
# etcd备份脚本 - 适用于K8s 1.31 (静态Pod模式)
# 前置条件: kubectl可访问集群, /etc/kubernetes/pki/etcd/证书存在
set -euo pipefail
umask 077

# === 参数化配置(兼容不同部署工具) ===
ETCD_CACERT="${ETCD_CACERT:-/etc/kubernetes/pki/etcd/ca.crt}"
ETCD_CERT="${ETCD_CERT:-/etc/kubernetes/pki/etcd/server.crt}"
ETCD_KEY="${ETCD_KEY:-/etc/kubernetes/pki/etcd/server.key}"
ETCD_ENDPOINT="${ETCD_ENDPOINT:-https://127.0.0.1:2379}"
BACKUP_DIR="${BACKUP_DIR:-/data/etcd-backup}"
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

# === 异地备份(OSS) ===
echo ">>> 异地备份到OSS..."
BACKUP_FILE="etcd-snapshot-${DATE}.db"
if command -v ossutil &>/dev/null; then
  ossutil cp ${BACKUP_DIR}/${BACKUP_FILE} oss://${OSS_BUCKET:-etcd-backup}/$(date +%Y%m%d)/${BACKUP_FILE} 2>/dev/null && \
    echo "  ✅ OSS上传成功" || \
    echo "  ⚠️  OSS上传失败，请检查ossutil配置"
else
  echo "  ℹ️  ossutil未安装，跳过OSS上传"
  echo "  [生产建议] 安装ossutil并配置异地备份: ossutil config -e oss-cn-hangzhou.aliyuncs.com"
fi

# === 告警通知 ===
echo ">>> 备份状态通知..."
BACKUP_SIZE=$(stat -f%z "${BACKUP_DIR}/${BACKUP_FILE}" 2>/dev/null || stat -c%s "${BACKUP_DIR}/${BACKUP_FILE}" 2>/dev/null)
if [ "${BACKUP_SIZE}" -gt 0 ] 2>/dev/null; then
  echo "  ✅ etcd备份完成: ${BACKUP_FILE} ($(numfmt --to=iec ${BACKUP_SIZE:-0}))"
else
  echo "  ❌ etcd备份失败: 文件为空"
fi
