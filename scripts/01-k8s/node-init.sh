#!/bin/bash
# K8s集群初始化脚本 - 所有节点执行
# 适用于K8s 1.28 + containerd
# 版本配置(修改此处锁定版本)
K8S_VERSION="${K8S_VERSION:-1.28}"
set -euo pipefail

NODE_IP=$(hostname -I | awk '{print $1}')
POD_CIDR="10.244.0.0/16"
SERVICE_CIDR="10.96.0.0/12"

echo "=== Step 1: 系统配置 ==="
cat >> /etc/sysctl.d/k8s.conf << EOF
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOF
sysctl --system

echo "=== Step 2: 关闭swap ==="
swapoff -a
sed -i '/ swap / s/^/#/' /etc/fstab

echo "=== Step 3: 安装containerd ==="
yum install -y yum-utils
yum-config-manager --add-repo https://mirrors.aliyun.com/docker-ce/linux/centos/docker-ce.repo
yum install -y containerd.io
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl enable containerd && systemctl restart containerd

echo "=== Step 4: 安装kubeadm/kubelet/kubectl ==="
cat > /etc/yum.repos.d/kubernetes.repo << EOF
[kubernetes]
name=Kubernetes
baseurl=https://mirrors.aliyun.com/kubernetes-new/core/stable/v1.28/rpm/
enabled=1
gpgcheck=1
gpgkey=https://mirrors.aliyun.com/kubernetes-new/core/stable/v1.28/rpm/repodata/repomd.xml.key
EOF
yum install -y kubelet-${K8S_VERSION}-0 kubeadm-${K8S_VERSION}-0 kubectl-${K8S_VERSION}-0
systemctl enable kubelet

echo "✅ 节点初始化完成，请在Master节点执行kubeadm init"
