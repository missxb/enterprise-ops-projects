#!/bin/bash
# K8s集群初始化脚本 - 所有节点执行
# 适用系统: CentOS 7.9 / Rocky Linux 8 / Ubuntu 22.04
# 适用于K8s 1.31 + containerd
# 依赖: kubeadm, kubelet, kubectl, containerd, curl
# 前置: 所有节点已配置网络互通, 时间同步(NTP), 每个节点单独执行
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

NODE_IP=$(hostname -I | awk '{print $1}')
K8S_VERSION="${K8S_VERSION:-1.31}"
K8S_PKG_VERSION="${K8S_PKG_VERSION:-1.31.0}"  # 具体patch版本
POD_CIDR="${POD_CIDR:-10.244.0.0/16}"
SERVICE_CIDR="${SERVICE_CIDR:-10.96.0.0/12}"

# 幂等性检查(重复执行时跳过已完成的步骤)
if kubectl get nodes &>/dev/null && kubectl get node $(hostname) --show-labels 2>/dev/null | grep -q 'node.kubernetes.io'; then
  log_info "此节点已初始化(K8s已安装)，跳过初始化"
  log_info "如需重新初始化，请先执行: kubeadm reset -f"
  exit 0
fi

# 检测包管理器
if command -v apt-get &>/dev/null; then
  PKG_MGR="apt"
else
  PKG_MGR="yum"
fi

log_info "=== Step 1: 系统配置 ==="
log_info "节点IP: ${NODE_IP}"
log_info "包管理器: ${PKG_MGR}"
log_info "K8s版本: ${K8S_PKG_VERSION}"

# 关闭swap
swapoff -a
sed -i '/swap/s/^/#/' /etc/fstab

# 内核参数
cat > /etc/sysctl.d/k8s.conf << EOF
# K8s必要参数
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
# 生产环境推荐参数
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 30
net.core.somaxconn = 65535
vm.max_map_count = 262144
vm.swappiness = 10
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 8192
EOF
sysctl --system

# 防火墙(K8s不支持firewalld)
if systemctl is-active firewalld &>/dev/null; then
  systemctl stop firewalld
  systemctl disable firewalld
  log_info "已关闭firewalld"
fi

# SELinux(生产环境使用permissive而非disabled，便于审计)
if [ -f /etc/selinux/config ]; then
  sed -i 's/SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config
  setenforce 0 2>/dev/null || true
  # [注意] K8s节点建议permissive模式(记录违规但不阻止)
  # 完全disabled会丢失安全审计日志
fi

log_info "=== Step 2: 安装containerd ==="
if [ "$PKG_MGR" = "apt" ]; then
  apt-get update
  apt-get install -y containerd
else
  yum install -y yum-utils
  yum-config-manager --add-repo https://mirrors.aliyun.com/docker-ce/linux/centos/docker-ce.repo
  yum install -y containerd.io
fi

# 配置containerd
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl restart containerd
systemctl enable containerd

log_info "=== Step 3: 安装K8s组件 ==="
if [ "$PKG_MGR" = "apt" ]; then
  curl -fsSL https://mirrors.aliyun.com/kubernetes-new/core/stable/v${K8S_VERSION}/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes.gpg
  echo "deb [signed-by=/etc/apt/keyrings/kubernetes.gpg] https://mirrors.aliyun.com/kubernetes-new/core/stable/v${K8S_VERSION}/deb/ /" > /etc/apt/sources.list.d/kubernetes.list
  apt-get update
  apt-get install -y kubelet=${K8S_PKG_VERSION}-0 kubeadm=${K8S_PKG_VERSION}-0 kubectl=${K8S_PKG_VERSION}-0
else
  cat > /etc/yum.repos.d/kubernetes.repo << EOF
[kubernetes]
name=Kubernetes
baseurl=https://mirrors.aliyun.com/kubernetes-new/core/stable/v${K8S_VERSION}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://mirrors.aliyun.com/kubernetes-new/core/stable/v${K8S_VERSION}/rpm/repodata/repomd.xml.key
EOF
  yum install -y kubelet-${K8S_PKG_VERSION} kubeadm-${K8S_PKG_VERSION} kubectl-${K8S_PKG_VERSION}
fi

systemctl enable kubelet

log_ok "节点初始化完成: ${NODE_IP}"
log_info "下一步: Master节点执行 kubeadm init"
