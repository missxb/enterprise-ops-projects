#!/bin/bash
# etcd恢复脚本
# 依赖: etcdctl, 备份快照文件
# 前置: 所有etcd节点已停止kube-apiserver和etcd
# 恢复步骤: 1.停止所有节点 2.每个节点分别运行此脚本 3.启动etcd 4.验证集群
# === 多节点恢复说明 ===
# 对于3节点etcd集群，恢复时需要在所有节点上执行此脚本：
# 1. 停止所有节点的etcd和kube-apiserver
# 2. 在每个节点上分别运行此脚本，使用同一个备份文件
# 3. 每个节点的 --initial-cluster 参数必须包含所有节点的完整集群信息
# 4. 恢复完成后先启动第1个节点，确认健康后再启动其余节点
# 5. 验证命令: etcdctl endpoint status --endpoints=<所有节点> --write-out=table
# 注意: 如果集群中有节点永久丢失，需先从恢复节点执行 member remove
set -euo pipefail
umask 077

# === 日志配置 ===
LOG_DIR="/var/log/k8s-ops"
LOG_FILE="${LOG_DIR}/$(basename $0 .sh)-$(date +%Y%m%d).log"
mkdir -p ${LOG_DIR}

log() {
    local level=$1; shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${level}] $*" | tee -a ${LOG_FILE}
}

log_info() { log "INFO" "$@"; }
log_warn() { log "WARN" "$@"; }
log_error() { log "ERROR" "$@"; }
log_ok()   { log "OK"   "$@"; }

# 错误处理
trap 'log_error "脚本执行失败，行号: $LINENO"' ERR

# [回滚] 如恢复失败，可从备份目录恢复: cp -r ${BACKUP_DIR}/etcd-*.bak /var/lib/etcd/

ETCD_ENDPOINT="${ETCD_ENDPOINT:-https://127.0.0.1:2379}"
ETCD_CACERT="${ETCD_CACERT:-/etc/kubernetes/pki/etcd/ca.crt}"
ETCD_CERT="${ETCD_CERT:-/etc/kubernetes/pki/etcd/server.crt}"
ETCD_KEY="${ETCD_KEY:-/etc/kubernetes/pki/etcd/server.key}"
BACKUP_FILE="${1:?用法: $0 <备份文件路径>}"

log_info "=== etcd恢复 ==="
log_warn "警告: 此操作将覆盖当前etcd数据!"

# 确认
# [修复] 支持CONFIRM环境变量用于非交互式执行(如CI/CD流水线)
# 用法: CONFIRM=yes ./etcd-restore.sh /path/to/backup
CONFIRM="${CONFIRM:-}"
if [ -z "${CONFIRM}" ]; then
  read -p "确认恢复? (yes/no): " CONFIRM
fi
[ "$CONFIRM" != "yes" ] && { log_info "已取消"; exit 0; }

# 停止所有etcd成员(3节点恢复需要先停止所有成员)
log_info "Step 1: 停止kube-apiserver和etcd..."
mv /etc/kubernetes/manifests/kube-apiserver.yaml /tmp/kube-apiserver.yaml.bak 2>/dev/null || true
# 停止etcd进程(如果是systemd管理)
systemctl stop etcd 2>/dev/null || true
# 或者通过静态Pod停止: 移动etcd manifest
mv /etc/kubernetes/manifests/etcd.yaml /tmp/etcd.yaml.bak 2>/dev/null || true
# 等待所有节点的etcd停止
  log_info "等待etcd停止..."
sleep 10
# 验证etcd已停止
if pgrep etcd >/dev/null 2>&1; then
  log_warn "etcd仍在运行，强制停止..."
  pkill -9 etcd || true
  sleep 3
fi

# 恢复etcd数据
log_info "Step 2: 恢复etcd数据..."
ETCDCTL_API=3 etcdctl snapshot restore "$BACKUP_FILE" \
  --data-dir=/var/lib/etcd-restore \
  --name=$(hostname) \
  --initial-cluster="${ETCD_CLUSTER:?请设置ETCD_CLUSTER(如etcd-0=https://10.10.10.11:2380,etcd-1=https://10.10.10.12:2380,etcd-2=https://10.10.10.13:2380)}" \
  --initial-advertise-peer-urls="https://127.0.0.1:2380" \
  --initial-cluster-token="etcd-cluster"

# 替换数据目录
log_info "Step 3: 替换数据目录..."
# 安全备份: 先检查是否已有.bak，避免覆盖之前的备份
if [ -d /var/lib/etcd.bak ]; then
  log_warn "发现已有备份 /var/lib/etcd.bak，使用时间戳重命名"
  mv /var/lib/etcd.bak /var/lib/etcd.bak.$(date +%Y%m%d%H%M%S)
fi
mv /var/lib/etcd /var/lib/etcd.bak
mv /var/lib/etcd-restore /var/lib/etcd

# 启动kube-apiserver
log_info "Step 4: 启动kube-apiserver..."
mv /tmp/kube-apiserver.yaml.bak /etc/kubernetes/manifests/kube-apiserver.yaml
sleep 10

# 验证
log_info "Step 5: 验证..."
ETCDCTL_API=3 etcdctl endpoint health \
  --endpoints=$ETCD_ENDPOINT \
  --cacert=$ETCD_CACERT \
  --cert=$ETCD_CERT \
  --key=$ETCD_KEY

log_ok "etcd恢复完成"
