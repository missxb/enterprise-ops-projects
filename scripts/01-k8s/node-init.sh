#!/bin/bash
# K8s集群初始化脚本 - 所有节点执行
# 适用系统: CentOS 7.9 / Rocky Linux 8 / Ubuntu 22.04
# 适用于K8s 1.31 + containerd
set -euo pipefail
umask 077

NODE_IP=$(hostname -I | awk '{print $1}')
K8S_VERSION="${K8S_VERSION:-1.31}"
K8S_PKG_VERSION="${K8S_PKG_VERSION:-1.31.0}"  # 具体patch版本
POD_CIDR="${POD_CIDR:-10.244.0.0/16}"
SERVICE_CIDR="${SERVICE_CIDR:-10.96.0.0/12}"

# 检测包管理器
if command -v apt-get &>/dev/null; then
  PKG_MGR="apt"
else
  PKG_MGR="yum"
fi

echo "=== Step 1: 系统配置 ==="
echo "节点IP: ${NODE_IP}"
echo "包管理器: ${PKG_MGR}"
echo "K8s版本: ${K8S_PKG_VERSION}"

# 关闭swap
swapoff -a
sed -i '/swap/s/^/#/' /etc/fstab

# 内核参数
cat > /etc/sysctl.d/k8s.conf << EOF
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOF
sysctl --system

# 防火墙(K8s不支持firewalld)
if systemctl is-active firewalld &>/dev/null; then
  systemctl stop firewalld
  systemctl disable firewalld
  echo "已关闭firewalld"
fi

# SELinux(生产环境使用permissive而非disabled，便于审计)
if [ -f /etc/selinux/config ]; then
  sed -i 's/SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config
  setenforce 0 2>/dev/null || true
  # [注意] K8s节点建议permissive模式(记录违规但不阻止)
  # 完全disabled会丢失安全审计日志
fi

echo "=== Step 2: 安装containerd ==="
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

echo "=== Step 3: 安装K8s组件 ==="
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

echo "✅ 节点初始化完成: ${NODE_IP}"
echo "下一步: Master节点执行 kubeadm init"
