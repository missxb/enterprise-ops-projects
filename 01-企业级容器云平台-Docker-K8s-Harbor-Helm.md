# 企业级容器云平台 - 基于 Docker + Kubernetes + Harbor + Helm 全栈部署
> 本项目完整实现一个企业级容器云平台，涵盖集群搭建、镜像仓库、应用编排、自动扩缩、日志收集、监控告警全链路。
> 适用于: 中大型互联网公司容器化改造、私有云PaaS平台建设
> 技术栈: Kubernetes 1.31 + containerd 2.0 + Harbor 2.12 + Helm 3 + Calico 3.28 + MetalLB

### 技术选型兼容性说明

> **containerd 2.0兼容性**：
> - containerd 2.0于2024年发布，提供CRI v1接口，与K8s 1.31完全兼容
> - 企业级建议：如需更稳定的版本，可使用containerd 1.7.x（LTS版本），功能上与2.0无显著差异
> - 本项目使用2.0是为了展示最新技术栈，实际生产环境可根据企业策略选择
>
> **Harbor 2.12与K8s 1.31兼容性**：
> - Harbor 2.12发布于2024年，经验证与K8s 1.31兼容
> - Harbor的Helm Chart（harbor/harbor）版本2.12+支持K8s 1.28-1.31
> - 注意：升级K8s前应先检查Harbor Release Notes中的兼容性矩阵
>
> **etcd备份增强**：生产环境etcd备份需考虑加密存储、跨区域复制、备份验证（见第十一节）
>
> **Harbor HA增强**：生产级Harbor HA需配置存储后端（S3/OSS）、镜像复制策略、GC策略（见第五节）
---
> ⚠️ **安全声明**: 本文档中的密码(如${MYSQL_ROOT_PASSWORD}、${HARBOR_ADMIN_PASSWORD}等)均为示例占位符。
> 生产环境必须使用密钥管理工具(Vault/K8s Secrets/环境变量)管理敏感信息，
> 脚本中 ${VARIABLE} 占位符需通过 envsubst 或 export 预设，直接执行会输出空值。
> 切勿将真实密码硬编码在配置文件或脚本中。
## 一、项目背景与目标
### 1.1 企业痛点
- 开发环境不一致，"在我机器上能跑"问题频发
- 微服务拆分后部署复杂度飙升，手动运维效率低
- 资源利用率低，服务器闲置率高达40-60%
- 缺乏统一的应用生命周期管理
### 1.2 项目目标
- 搭建生产级K8s集群（3 Master + N Worker）
- 部署Harbor私有镜像仓库（高可用+镜像扫描）
- 实现Helm Chart标准化应用交付
- 集成Prometheus+Grafana监控 + EFK日志
- 支持HPA自动扩缩 + PDBPod中断预算
### 1.3 架构总览
```
                    ┌─────────────────────────────────────────┐
                    │           Load Balancer (MetalLB)        │
                    │              VIP: 10.10.10.100           │
                    └──────────┬──────────┬──────────┬────────┘
                               │          │          │
                    ┌──────────┴┐  ┌──────┴──┐  ┌───┴──────────┐
                    │ Master-01 │  │ Master-02│  │  Master-03   │
                    │apiserver  │  │apiserver │  │  apiserver   │
                    │etcd       │  │etcd      │  │  etcd        │
                    │scheduler  │  │scheduler │  │  controller  │
                    └─────┬─────┘  └────┬─────┘  └──────┬───────┘
                          │             │               │
          ┌───────────────┴─────────────┴───────────────┴────────┐
          │                    Calico BGP 网络                     │
          └──┬──────┬──────┬──────┬──────┬──────┬──────┬────┬────┘
             │      │      │      │      │      │      │    │
          ┌──┴──┐┌──┴──┐┌──┴──┐┌──┴──┐┌──┴──┐
          │W-01 ││W-02 ││W-03 ││W-04 ││W-05 │
          │worker││worker││worker││worker││worker│
          └─────┘└─────┘└─────┘└─────┘└─────┘
```
### Pod Security Admission (PSA)
K8s 1.25+使用Pod Security Admission替代已废弃的PodSecurityPolicy:
```yaml
# 为命名空间启用PSA
apiVersion: v1
kind: Namespace
metadata:
  name: production
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
```
---
## 二、服务器规划
### 2.1 节点清单
| 角色 | 主机名 | IP | CPU | 内存 | 系统盘 | 数据盘 | 用途 |
|------|--------|-----|-----|------|--------|--------|------|
| Master | k8s-master-01 | 10.10.10.11 | 8C | 16G | 100G SSD | - | Control Plane |
| Master | k8s-master-02 | 10.10.10.12 | 8C | 16G | 100G SSD | - | Control Plane |
| Master | k8s-master-03 | 10.10.10.13 | 8C | 16G | 100G SSD | - | Control Plane |
| Worker | k8s-worker-01 | 10.10.10.21 | 16C | 64G | 100G SSD | 500G | 业务工作节点 |
| Worker | k8s-worker-02 | 10.10.10.22 | 16C | 64G | 100G SSD | 500G | 业务工作节点 |
| Worker | k8s-worker-03 | 10.10.10.23 | 16C | 64G | 100G SSD | 500G | 业务工作节点 |
| Worker | k8s-worker-04 | 10.10.10.24 | 32C | 128G | 100G SSD | 1T | 有状态/大内存应用 |
| Worker | k8s-worker-05 | 10.10.10.25 | 32C | 128G | 100G SSD | 1T | GPU/AI推理节点 |
| Harbor | harbor-01 | 10.10.10.31 | 8C | 16G | 100G SSD | 2T | 镜像仓库 |
| Harbor | harbor-02 | 10.10.10.32 | 8C | 16G | 100G SSD | 2T | 镜像仓库(备) |
> **Harbor生产级HA架构**:
> 1. 外部PostgreSQL(主备同步) — 使用阿里云RDS PostgreSQL或自建PG主备
> 2. 外部Redis(主备) — 使用阿里云Redis或自建Sentinel+3节点
> 3. 共享对象存储 — 使用阿里云OSS或NFS(避免本地存储)
> 4. HAProxy/Nginx负载均衡 — 双VIP或DNS轮询分发
> 5. 证书管理 — cert-manager自动签发+续期
> 6. 日志采集 — Filebeat收集Harbor日志到ELK
>
> 生产级部署脚本见 scripts/01-k8s/harbor-ha.sh
### 2.2 网络规划
| 网段 | 用途 |
|------|------|
| 10.10.10.0/24 | 节点管理网络 |
| 10.244.0.0/16 | Pod网络 (Calico) |
| 10.96.0.0/12 | Service网络 (ClusterIP) |
| 172.17.0.0/16 | Docker默认网桥(禁用) |
---
## 三、基础环境配置（所有节点执行）
### 3.1 系统初始化脚本
```bash
#!/bin/bash
# init_nodes.sh - 所有K8s节点执行
# 适用系统: CentOS 7.9 / Rocky Linux 8 (仅支持yum/dnf包管理器)
set -euo pipefail
echo "========== [1/8] 关闭Swap =========="
swapoff -a
sed -i '/swap/s/^/#/' /etc/fstab
echo "Swap已关闭"
echo "========== [2/8] 关闭SELinux =========="
setenforce 0 2>/dev/null || true
# [等保说明] K8s节点需permissive，等保三级要求enforcing
# 解决方案: 1)使用SELinux策略模块替代直接关闭 2)非K8s节点保持enforcing
sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config
echo "SELinux已关闭"
echo "========== [3/8] 关闭防火墙 =========="
# [K8s节点专用] K8s不兼容firewalld，生产环境使用NetworkPolicy
systemctl stop firewalld 2>/dev/null || true
systemctl disable firewalld 2>/dev/null || true
echo "防火墙已关闭"
echo "========== [4/8] 加载内核模块 =========="
cat > /etc/modules-load.d/k8s.conf << EOF
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter
echo "内核模块已加载"
echo "========== [5/8] 配置内核参数 =========="
cat > /etc/sysctl.d/k8s.conf << EOF
# K8s基础网络
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
net.ipv4.conf.all.forwarding        = 1

# TCP连接优化
net.ipv4.tcp_keepalive_time         = 600
net.ipv4.tcp_keepalive_intvl        = 30
net.ipv4.tcp_keepalive_probes       = 10
net.ipv4.ip_local_port_range        = 1024 65535  # 扩大本地端口范围（K8s NodePort需要）
net.ipv4.tcp_tw_reuse               = 1

# 网络队列
net.core.somaxconn                  = 65535
net.core.netdev_max_backlog         = 65535
net.core.netdev_budget              = 600
net.core.netdev_budget_usecs        = 8000

# 内存管理
vm.swappiness                       = 0
vm.overcommit_memory                = 1
vm.max_map_count                    = 262144  # Elasticsearch/数据库需要

# 文件系统
fs.inotify.max_user_watches         = 524288
fs.inotify.max_user_instances       = 8192
fs.file-max                         = 655360
fs.aio-max-nr                       = 1048576

# 安全参数
net.ipv4.conf.all.rp_filter        = 1
net.ipv4.conf.default.rp_filter    = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
EOF
sysctl --system > /dev/null 2>&1
echo "内核参数已配置"

echo "========== [5.1/8] 配置时间同步(Chrony) =========="
# 等保要求: 网络设备、安全设备、服务器等时间偏差不超过1秒
yum install -y chrony
cat > /etc/chrony.conf << EOF
# 中国NTP服务器
server ntp.aliyun.com iburst
server ntp1.aliyun.com iburst
server cn.pool.ntp.org iburst

# 允许局域网内其他节点同步
allow 10.10.10.0/24

# 即使未同步也作为时间服务器
local stratum 10

# 记录时间偏移
driftfile /var/lib/chrony/drift

# 启用时间步进限制
makestep 1.0 3

# 时钟同步日志
logdir /var/log/chrony
EOF
systemctl enable chronyd
systemctl restart chronyd
# 验证时间同步
chronyc sources -v
echo "时间同步已配置"

echo "========== [5.2/8] 配置DNS解析优化 =========="
# DNS缓存和解析优化
cat > /etc/resolv.conf << EOF
nameserver 10.10.10.11  # Master-01 (CoreDNS)
nameserver 223.5.5.5    # 阿里云DNS
nameserver 114.114.114.114
search cluster.local svc.cluster.local
options ndots:5 timeout:2 attempts:3 rotate
EOF
echo "DNS解析已优化"
echo "========== [6/8] 安装containerd =========="
# Docker已内置containerd，也可独立安装
yum install -y yum-utils device-mapper-persistent-data lvm2
yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
yum install -y containerd.io
# 配置containerd
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
# 启用SystemdCgroup
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
# 配置镜像加速(用户指定)
# [注意] 部分镜像站已停用或限流(2024+):
#   - tuna.tsinghua.edu.cn: Docker Hub代理已停用
#   - daocloud.io: 已限流
#   建议使用内网Harbor作为pull-through cache，或使用云厂商镜像加速
mkdir -p /etc/containerd/certs.d/docker.io
cat > /etc/containerd/certs.d/docker.io/hosts.toml << EOF
server = "https://docker.io"
# 推荐: 使用内网Harbor作为pull-through cache加速镜像拉取
# 前提: 已配置内网Harbor registry并通过containerd certs.d信任
[host."https://harbor.internal.com"]
  capabilities = ["pull", "resolve"]
  skip_verify = false
EOF
sed -i 's|sandbox_image = "registry.k8s.io/pause:.*"|sandbox_image = "registry.k8s.io/pause:3.9"|' /etc/containerd/config.toml
# [已修复] 镜像加速已迁移到certs.d目录
systemctl daemon-reload
systemctl enable containerd
systemctl restart containerd
echo "containerd已安装配置"
echo "========== [7/8] 安装kubeadm/kubelet/kubectl =========="
cat > /etc/yum.repos.d/kubernetes.repo << EOF
[kubernetes]
name=Kubernetes
# 国内环境可替换为阿里云镜像: https://mirrors.aliyun.com/kubernetes-new/core/stable/v1.31/rpm/
baseurl=https://pkgs.k8s.io/core:/stable:/v1.31/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v1.31/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
EOF
yum install -y kubelet-1.31.0 kubeadm-1.31.0 kubectl-1.31.0 --disableexcludes=kubernetes
systemctl enable kubelet
echo "kubeadm/kubelet/kubectl已安装"
echo "========== [8/8] 配置hosts =========="
cat >> /etc/hosts << EOF
10.10.10.11 k8s-master-01
10.10.10.12 k8s-master-02
10.10.10.13 k8s-master-03
10.10.10.21 k8s-worker-01
10.10.10.22 k8s-worker-02
10.10.10.23 k8s-worker-03
10.10.10.24 k8s-worker-04
10.10.10.25 k8s-worker-05
10.10.10.31 harbor-01
10.10.10.32 harbor-02
EOF
echo ""
echo "✅ 所有节点初始化完成！请重启后继续。"
```
---
## 四、高可用Kubernetes集群搭建
### 4.1 HAProxy + Keepalived 负载均衡（Master-01执行）
```bash
#!/bin/bash
# install_haproxy_keepalived.sh - 在前两台Master上安装LB
# 本脚本在 Master-01 上执行，同时也会配置到 Master-02
set -euo pipefail
VIP="10.10.10.100"
MASTER01="10.10.10.11"
MASTER02="10.10.10.12"
MASTER03="10.10.10.13"
echo "安装HAProxy..."
yum install -y haproxy
cat > /etc/haproxy/haproxy.cfg << HAPCFG
global
    log         /dev/log local0
    log         /dev/log local1 notice
    chroot      /var/lib/haproxy
    pidfile     /var/run/haproxy.pid
    maxconn     50000
    user        haproxy
    group       haproxy
    daemon
    stats socket /var/lib/haproxy/haproxy.sock mode 600 level admin
    tune.ssl.default-dh-param 2048
defaults
    log     global
    mode    tcp
    option  tcplog
    option  dontlognull
    timeout connect 5s
    timeout client  30s
    timeout server  30s
    retries 3
# Kubernetes API Server 负载均衡
frontend k8s_apiserver_bind
    bind ${VIP}:6443
    default_backend k8s_apiserver
backend k8s_apiserver
    option tcp-check
    balance roundrobin
    server master01 ${MASTER01}:6443 check inter 3s fall 3 rise 2
    server master02 ${MASTER02}:6443 check inter 3s fall 3 rise 2
    server master03 ${MASTER03}:6443 check inter 3s fall 3 rise 2
# HAProxy Stats
frontend stats
    bind *:8404
    mode http
    stats enable
    stats uri /stats
    stats refresh 10s
    stats admin if LOCALHOST
HAPCFG
systemctl enable haproxy
systemctl restart haproxy
echo "安装Keepalived..."
yum install -y keepalived
cat > /etc/keepalived/keepalived.conf << KVCFG
! Keepalived for K8s API Server HA
! [注意] auth_pass和VIP使用shell变量(${KEEPALIVED_AUTH_PASS:-CHANGEME})，
! heredoc必须不加引号(<< KVCFG 而非 << 'KVCFG')才能展开变量。
! 如果直接复制配置文件而非执行脚本，需先用sed替换占位符：
!   sed -i 's/\${KEEPALIVED_AUTH_PASS:-CHANGEME}/实际密码/' /etc/keepalived/keepalived.conf
!   sed -i 's|\${VIP}/24 dev \${KEEPALIVED_IFACE:-eth0}|实际VIP/24 dev 实际网卡|' /etc/keepalived/keepalived.conf
! auth_pass限制: 最多8个字符(Keepalived硬编码限制),超出会被截断
global_defs {
    router_id LVS_K8S_MASTER
    script_user root
    enable_script_security
}
vrrp_script check_haproxy {
    script "/usr/bin/systemctl is-active haproxy"
    interval 2
    weight -20
    fall 3
    rise 2
}
vrrp_instance K8S_VIP {
    state MASTER          # 其他节点改为BACKUP
    # [接口说明] Keepalived >= 1.3.7 自动选择默认网卡，无需指定interface字段
    # 如需强制绑定指定网卡(多网卡场景)，取消注释并修改:
    # interface eth0  # 替换为实际网卡名(ip route show default查看)
    virtual_router_id 51
    priority 101          # MASTER=101, BACKUP=100
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass ${KEEPALIVED_AUTH_PASS:-CHANGEME}  # 通过.env注入,或: openssl rand -hex 4
    }
    virtual_ipaddress {
        ${VIP}/24 dev ${KEEPALIVED_IFACE:-eth0}  # 通过KEEPALIVED_IFACE环境变量指定，默认eth0
    }
    track_script {
        check_haproxy
    }
    notify_master "/bin/echo 'MASTER' > /tmp/keepalived_state"
    notify_backup "/bin/echo 'BACKUP' > /tmp/keepalived_state"
}
KVCFG
systemctl enable keepalived
systemctl restart keepalived
echo "✅ HAProxy + Keepalived 配置完成"
echo "VIP: ${VIP}"
```
### 4.2 初始化Kubernetes集群
```bash
#!/bin/bash
# init_k8s_cluster.sh - 在Master-01上执行
set -euo pipefail
VIP="10.10.10.100"
POD_CIDR="10.244.0.0/16"
SERVICE_CIDR="10.96.0.0/12"
SERVICE_DOMAIN="cluster.local"
echo "========== 创建kubeadm配置文件 =========="
cat > /tmp/kubeadm-config.yaml << EOF
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: 10.10.10.11
  bindPort: 6443
nodeRegistration:
  criSocket: unix:///var/run/containerd/containerd.sock
  imagePullPolicy: IfNotPresent
  name: k8s-master-01
  taints:
    - effect: NoSchedule
      key: node-role.kubernetes.io/control-plane
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: v1.31.0
controlPlaneEndpoint: "${VIP}:6443"
imageRepository: registry.aliyuncs.com/google_containers  # [阿里云镜像加速]
# [镜像源说明]
# 1. kubeadm imageRepository: 控制面组件镜像(apiserver, scheduler, etc.)
# 2. containerd certs.d: 应用容器镜像(docker.io上的镜像)
# 3. Harbor: 业务应用镜像(私有仓库)
# 三处镜像策略不同是正常的，但需确保内网环境三者均可访问
networking:
  dnsDomain: ${SERVICE_DOMAIN}
  podSubnet: ${POD_CIDR}
  serviceSubnet: ${SERVICE_CIDR}
certificatesDir: /etc/kubernetes/pki
clusterName: enterprise-k8s
etcd:
  local:
    extraArgs:
      listen-metrics-urls: http://0.0.0.0:2381
      quota-backend-bytes: "4294967296"  # 4GB，etcd默认2GB，最大8GB
      auto-compaction-retention: "8"
apiServer:
  extraArgs:
    audit-log-path: /var/log/kubernetes/audit.log
    audit-log-maxage: "30"
    audit-log-maxbackup: "10"
    audit-log-maxsize: "100"
    enable-admission-plugins: "NamespaceLifecycle,LimitRanger,ServiceAccount,DefaultStorageClass,MutatingAdmissionWebhook,ValidatingAdmissionWebhook,ResourceQuota"
    event-ttl: "720h"
    request-timeout: "300s"
    watch-cache: "true"
  extraVolumes:
    - name: audit-log
      hostPath: /var/log/kubernetes
      mountPath: /var/log/kubernetes
      readOnly: false
controllerManager:
  extraArgs:
    terminated-pod-gc-threshold: "100"
    node-monitor-period: "5s"
    node-monitor-grace-period: "40s"
    pod-eviction-timeout: "5m0s"
scheduler:
  extraArgs:
    profiling: "false"
EOF
echo "预拉取镜像..."
kubeadm config images pull --config /tmp/kubeadm-config.yaml
echo "初始化集群..."
kubeadm init --config /tmp/kubeadm-config.yaml --upload-certs
echo "配置kubectl..."
mkdir -p $HOME/.kube
cp -f /etc/kubernetes/admin.conf $HOME/.kube/config
chown $(id -u):$(id -g) $HOME/.kube/config
echo "验证集群..."
kubectl get nodes
kubectl get pods -A
echo "✅ Master-01 初始化完成"
echo ""
echo "请保存以下命令，在其他Master节点上执行:"
kubeadm token create --print-join-command --certificate-ttl 2h
```
### 4.3 加入其他Master节点
```bash
#!/bin/bash
# join_masters.sh - 在Master-02和Master-03上分别执行
# 注意: 先修改 /etc/keepalived/keepalived.conf 中的 state 和 priority
set -euo pipefail
echo "========== 配置Keepalived为BACKUP =========="
# Master-02: state=BACKUP, priority=100
# Master-03: state=BACKUP, priority=99
# (请根据实际节点修改)
echo "========== 加入集群 =========="
# 使用Master-01生成的join命令，例如:
kubeadm join 10.10.10.100:6443 \
  --token <token> \
  --discovery-token-ca-cert-hash sha256:<hash> \
  --control-plane \
  --certificate-key <cert-key> \
  --apiserver-advertise-address <本机IP>
echo "配置kubectl..."
mkdir -p $HOME/.kube
scp k8s-master-01:/etc/kubernetes/admin.conf $HOME/.kube/config
chown $(id -u):$(id -g) $HOME/.kube/config
echo "验证..."
kubectl get nodes
```
### 4.4 Worker节点加入集群
```bash
#!/bin/bash
# join_workers.sh - 在所有Worker节点上执行
set -euo pipefail
# 使用Master-01生成的普通join命令
kubeadm join 10.10.10.100:6443 \
  --token <token> \
  --discovery-token-ca-cert-hash sha256:<hash>
```
### 4.5 安装Calico网络插件
```bash
#!/bin/bash
# install_calico.sh - 在Master-01上执行
set -euo pipefail
echo "安装Calico..."
# 使用operator方式安装
# Calico v3.28 支持 K8s 1.31，修复了 3.26 中多个已知的 BGP 路由泄漏问题
# 变更: 3.26→3.28 升级了 Felix 的 conntrack 回收逻辑，提升了大规模集群下的稳定性
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/tigera-operator.yaml
cat > /tmp/custom-resources.yaml << EOF
apiVersion: operator.tigera.io/v1
kind: Installation
metadata:
  name: default
spec:
  calicoNetwork:
    ipPools:
    - name: default-ipv4-ippool
      blockSize: 26
      cidr: 10.244.0.0/16
      encapsulation: None  # BGP模式不使用封装
      natOutgoing: true
      nodeSelector: all()
    nodeAddressAutodetectionV4:
      interface: eth.*
  registry: quay.io
---
apiVersion: operator.tigera.io/v1
kind: APIServer
metadata:
  name: default
spec: {}
EOF
kubectl apply -f /tmp/custom-resources.yaml
echo "等待Calico就绪..."
kubectl -n calico-system rollout status daemonset/calico-node --timeout=300s
echo "验证网络..."
kubectl get pods -n calico-system
kubectl get ippool -o wide
```
### 4.6 安装MetalLB（裸金属负载均衡）
> ⚠️ MetalLB L2模式要求同一VLAN，云环境(阿里云/AWS)不支持ARP广播，应使用云厂商SLB/CLB替代。
```bash
#!/bin/bash
# install_metallb.sh - Master-01执行
set -euo pipefail
echo "安装MetalLB..."
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.5/config/manifests/metallb-native.yaml
echo "等待MetalLB就绪..."
kubectl -n metallb-system rollout status daemonset/speaker --timeout=300s
echo "配置IP地址池..."
cat > /tmp/metallb-config.yaml << EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
# MetalLB v0.14.x API版本: metallb.io/v1beta1 ( IPAddressPool ) / metallb.io/v1beta2 (L2Advertisement)
metadata:
  name: production-pool
  namespace: metallb-system
spec:
  addresses:
  - 10.10.10.200-10.10.10.240   # 41个可用IP，与节点同子网(10.10.10.0/24)
  # [重要] L2模式要求: MetalLB IP池必须与节点在同一二层网络(同一VLAN)
  # 当前节点在10.10.10.0/24，IP池已配置在同一子网内
  # 生产建议: 大规模集群建议使用BGP模式或云厂商LoadBalancer替代MetalLB
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: default
  namespace: metallb-system
spec:
  ipAddressPools:
  - production-pool
EOF
kubectl apply -f /tmp/metallb-config.yaml
echo "✅ MetalLB配置完成，IP池: 10.10.10.200-10.10.10.240"
```

### 4.7 CSI存储方案配置

> **存储选型**：根据环境选择合适的CSI驱动
> - **私有云/裸金属**：NFS（简单）、Ceph-RBD（高性能）、Longhorn（轻量）
> - **公有云**：云厂商CSI（阿里云disk-ssd、AWS EBS、Azure Disk）
> - **混合云**：Rook-Ceph（统一存储）

```bash
#!/bin/bash
# install_csi.sh - 安装CSI存储驱动（以NFS为例）
set -euo pipefail

echo "========== 部署NFS CSI Driver =========="
# 使用NFS作为默认StorageClass（适用于私有云/测试环境）
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/master/deploy/csi-nfs-controller.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/master/deploy/csi-nfs-node.yaml

# 创建StorageClass
cat > /tmp/storageclass-nfs.yaml << EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: nfs-client
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: nfs.csi.k8s.io
parameters:
  server: 10.10.10.41
  share: /data/nfs
reclaimPolicy: Retain
allowVolumeExpansion: true
volumeBindingMode: Immediate
mountOptions:
  - hard
  - nfsvers=4.1
EOF
kubectl apply -f /tmp/storageclass-nfs.yaml

# 验证StorageClass
kubectl get sc
```

```yaml
# storageclass-ceph.yaml - Ceph-RBD StorageClass（适用于生产环境）
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ceph-rbd
provisioner: rbd.csi.ceph.com
parameters:
  clusterID: <ceph-cluster-id>
  pool: kubernetes
  csi.storage.k8s.io/provisioner-secret-name: csi-rbd-secret
  csi.storage.k8s.io/provisioner-secret-namespace: default
  csi.storage.k8s.io/node-stage-secret-name: csi-rbd-secret
  csi.storage.k8s.io/node-stage-secret-namespace: default
  imageFeatures: layering
reclaimPolicy: Delete
allowVolumeExpansion: true
volumeBindingMode: WaitForFirstConsumer
mountOptions:
  - discard
```

> **快照策略**：配置PV快照，支持数据备份和恢复

```yaml
# volume-snapshot-class.yaml
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshotClass
metadata:
  name: csi-snapclass
driver: nfs.csi.k8s.io  # 替换为实际CSI驱动
deletionPolicy: Delete
---
# volume-snapshot.yaml - 定期快照示例
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: pvc-snapshot-$(date +%Y%m%d)
  namespace: default
spec:
  volumeSnapshotClassName: csi-snapclass
  source:
    persistentVolumeClaimName: app-data-pvc
```

---
## 五、Harbor私有镜像仓库部署
### 5.1 Harbor安装与配置
```bash
#!/bin/bash
# install_harbor.sh - 在harbor-01上执行
set -euo pipefail
HARBOR_VERSION="2.12.0"
HARBOR_DOMAIN="${HARBOR_DOMAIN:-harbor.internal.com}"  # 生产环境通过.env注入
HARBOR_IP="10.10.10.31"
echo "安装Docker Compose..."
yum install -y docker-compose-plugin  # 或: dnf install -y docker-compose-plugin
# [注意] docker-compose-plugin安装后提供docker compose(无连字符)命令
# 如需独立docker-compose(连字符)二进制，可手动下载:
# curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" \
#   -o /usr/local/bin/docker-compose && chmod +x /usr/local/bin/docker-compose
echo "下载Harbor..."
cd /opt
# [安装方式选择]
# - offline版: harbor-offline-installer-v${HARBOR_VERSION}.tgz (~800MB，含所有镜像)
#   适用于: 无公网环境、生产环境、批量部署
# - online版:  harbor-online-installer-v${HARBOR_VERSION}.tgz (~20MB，运行时拉取镜像)
#   适用于: 有公网环境、快速验证、测试环境
# 生产环境推荐使用offline版，避免部署期间因网络问题导致镜像拉取失败
wget https://github.com/goharbor/harbor/releases/download/v${HARBOR_VERSION}/harbor-offline-installer-v${HARBOR_VERSION}.tgz
tar xzf harbor-offline-installer-v${HARBOR_VERSION}.tgz
cd harbor
echo "生成证书..."
mkdir -p /opt/harbor/certs
cd /opt/harbor/certs
# CA根证书
# [生产建议] 使用cert-manager自动管理证书，避免手动openssl操作:
# helm install cert-manager jetstack/cert-manager --namespace cert-manager --create-namespace --set installCRDs=true
openssl genrsa -out ca.key 4096
openssl req -x509 -new -nodes -sha512 -days 1095 \
  -subj "/C=CN/ST=Beijing/L=Beijing/O=Enterprise/CN=Harbor-CA" \
  -key ca.key -out ca.crt
# Harbor服务器证书
openssl genrsa -out harbor.key 4096
openssl req -sha512 -new \
  -subj "/C=CN/ST=Beijing/L=Beijing/O=Enterprise/CN=${HARBOR_DOMAIN}" \
  -key harbor.key -out harbor.csr
cat > v3.ext << EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage=digitalSignature,nonRepudiation,keyEncipherment,dataEncipherment
extendedKeyUsage=serverAuth
subjectAltName=@alt_names
[alt_names]
DNS.1=${HARBOR_DOMAIN}
DNS.2=harbor-01
IP.1=${HARBOR_IP}
EOF
openssl x509 -req -sha512 -days 1095 \
  -extfile v3.ext -CA ca.crt -CAkey ca.key -CAcreateserial \
  -in harbor.csr -out harbor.crt
# 配置Docker信任证书
mkdir -p /etc/docker/certs.d/${HARBOR_DOMAIN}
cp harbor.crt /etc/docker/certs.d/${HARBOR_DOMAIN}/ca.crt
# Harbor私钥不应放在certs.d目录，应放在权限严格的目录
mkdir -p /opt/harbor/certs
cp harbor.key /opt/harbor/certs/
chmod 600 /opt/harbor/certs/harbor.key
cp ca.crt /etc/docker/certs.d/${HARBOR_DOMAIN}/
# ca.key也不应放在certs.d
cp ca.key /opt/harbor/certs/
chmod 600 /opt/harbor/certs/ca.key
# 将CA证书加入系统信任
cp ca.crt /etc/pki/ca-trust/source/anchors/harbor-ca.crt
update-ca-trust
echo "配置Harbor..."
cd /opt/harbor
cp harbor.yml.tmpl harbor.yml
cat > harbor.yml << HARBORYML
hostname: ${HARBOR_DOMAIN}
http:
  port: 80
https:
  port: 443
  certificate: /opt/harbor/certs/harbor.crt
  private_key: /opt/harbor/certs/harbor.key
harbor_admin_password: ${HARBOR_ADMIN_PASSWORD}
database:
  password: ${HARBOR_DB_PASSWORD}
  max_idle_conns: 100
  max_open_conns: 900
  conn_max_lifetime: 5m
  conn_max_idle_time: 0
data_volume: /data/harbor
storage_service:
  s3:
    disabled: true
jobservice:
  max_job_workers: 10
  job_loggers:
    - STD_OUTPUT
    - FILE
    - DATABASE
  logger_sweeper_duration: 1 #days
log:
  level: info
  local:
    rotate_count: 50
    rotate_size: 200M
    location: /var/log/harbor
uaa:
  enabled: false
trace:
  enabled: true
  sample_rate: 1
  jaeger:
    endpoint: http://jaeger:14268/api/traces
HARBORYML
echo "安装Harbor..."
# [已修复] Harbor 2.9+已废弃chartmuseum，移除--with-chartmuseum参数
./install.sh --with-trivy
echo "配置开机自启..."
cat > /etc/systemd/system/harbor.service << EOF
[Unit]
Description=Harbor Container Registry
After=docker.service
Requires=docker.service
[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/harbor
ExecStart=/usr/bin/docker compose -f /opt/harbor/docker-compose.yml up -d
ExecStop=/usr/bin/docker compose -f /opt/harbor/docker-compose.yml down
TimeoutStartSec=0
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable harbor
echo "✅ Harbor安装完成"
echo "访问: https://${HARBOR_DOMAIN}"
echo "用户名: admin / 密码: ${HARBOR_ADMIN_PASSWORD}"
```
### 5.2 配置K8s节点信任Harbor
```bash
#!/bin/bash
# trust_harbor.sh - 在所有K8s节点上执行
set -euo pipefail
HARBOR_DOMAIN="${HARBOR_DOMAIN:-harbor.internal.com}"  # 生产环境通过.env注入
echo "创建namespace..."
kubectl create namespace harbor-system
echo "创建Harbor拉取Secret..."
kubectl create secret docker-registry harbor-secret \
  --docker-server=${HARBOR_DOMAIN} \
  --docker-username=admin \
  --docker-password=${HARBOR_ADMIN_PASSWORD} \
  -n default
echo "配置containerd信任Harbor..."
cat > /etc/containerd/certs.d/${HARBOR_DOMAIN}/hosts.toml << EOF
server = "https://${HARBOR_DOMAIN}"
[host."https://${HARBOR_DOMAIN}"]
  capabilities = ["pull", "resolve"]
  skip_verify = false  # 已在上方步骤分发CA证书到所有节点
EOF
systemctl restart containerd
echo "✅ K8s节点已信任Harbor"
```

### 5.3 Harbor生产级HA配置

> **存储后端配置**：生产环境Harbor必须使用共享存储（S3/OSS/NFS），避免本地存储单点故障

```bash
# harbor-ha.yml - Harbor HA配置（外部PG/Redis + S3存储）
# 修改harbor.yml中的storage_service部分
storage_service:
  s3:
    accesskey: ${AWS_ACCESS_KEY_ID}
    secretkey: ${AWS_SECRET_ACCESS_KEY}
    region: cn-beijing
    bucket: harbor-registry-prod
    # 跨区域复制桶（异地容灾）
    # regionendpoint: https://s3.cn-north-1.amazonaws.com.cn  # AWS中国区
  cache:
    enabled: true
    source_capacity: 500MB
    layer_cache_capacity: 10GB
  delete:
    enabled: true  # 启用删除策略
  redirect:
    disable: false
```

> **镜像复制策略**：配置跨数据中心镜像复制，实现异地容灾

```bash
# 通过Harbor API配置镜像复制规则
curl -k -u admin:${HARBOR_ADMIN_PASSWORD} \
  -X POST "https://harbor.internal.com/api/v2.0/replication/policies" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "prod-to-dr",
    "src_registry": null,
    "dest_registry": {
      "id": 1,
      "name": "harbor-dr"
    },
    "dest_namespace": "production",
    "trigger": {
      "type": "event_based"
    },
    "filters": [
      {"type": "name", "value": "**"},
      {"type": "tag", "value": "v*"}
    ],
    "enabled": true,
    "deletion_policy": {
      "deletion": false
    }
  }'
```

> **GC策略**：配置镜像垃圾回收，清理未引用的Blob

```bash
# harbor_gc.sh - 定期执行镜像GC
#!/bin/bash
# 通过Harbor API触发GC（每天凌晨2点）
curl -k -u admin:${HARBOR_ADMIN_PASSWORD} \
  -X POST "https://harbor.internal.com/api/v2.0/system/gc/schedule" \
  -H "Content-Type: application/json" \
  -d '{
    "parameters": {
      "delete_untagged": true,
      "dry_run": false,
      "workers": 3
    },
    "schedule": {
      "type": "Custom",
      "cron": "0 2 * * *"
    }
  }'
# crontab: 0 2 * * * /opt/scripts/harbor_gc.sh >> /var/log/harbor-gc.log 2>&1
```
---
## 六、Helm Chart应用编排
### 6.1 安装Helm并配置仓库
```bash
#!/bin/bash
# install_helm.sh - Master-01执行
set -euo pipefail
echo "安装Helm..."
# Helm 3 官方安装方式 (yum默认仓库无helm包)
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
# 或使用离线/国内镜像:
# curl https://get.helm.sh/helm-v3.14.0-linux-amd64.tar.gz | tar xz && mv linux-amd64/helm /usr/local/bin/
echo "添加常用仓库..."
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo add jetstack https://charts.jetstack.io
helm repo add harbor https://helm.goharbor.io
helm repo update
echo "验证..."
helm version
helm repo list
```
### 6.2 企业级应用部署示例 - 电商微服务
```yaml
# values-ecommerce.yaml - 通过Helm部署电商微服务架构
# helm install ecommerce ./ecommerce-stack -f values-ecommerce.yaml -n production
# ========================================
# 全局配置
# ========================================
global:
  imageRegistry: harbor.internal.com/production
  imagePullSecrets:
    - name: harbor-secret
  environment: production
  region: cn-beijing
# ========================================
# Nginx Ingress Controller
# =================================
... [OUTPUT TRUNCATED - 111 chars omitted out of 50111 total] ...
      maxReplicas: 15
      targetCPUUtilizationPercentage: 65
    healthCheck:
      path: /health
      port: 8080
      initialDelaySeconds: 30
      periodSeconds: 10
    podDisruptionBudget:
      enabled: true
      minAvailable: 2
    topologySpreadConstraints:
      - maxSkew: 1
        topologyKey: kubernetes.io/hostname
        whenUnsatisfiable: DoNotSchedule
        labelSelector:
          matchLabels:
            app: user-service
  # 商品服务
  product-service:
    replicaCount: 3
    image:
      repository: harbor.internal.com/production/product-service
      tag: v1.8.5
    ports:
      containerPort: 8081
    env:
      - name: DB_HOST
        value: "ecommerce-mysql-primary"
      - name: CACHE_HOST
        value: "ecommerce-redis-master"
    resources:
      requests:
        cpu: 250m
        memory: 512Mi
      limits:
        cpu: 1000m
        memory: 1Gi
    autoscaling:
      enabled: true
      minReplicas: 3
      maxReplicas: 20
      targetCPUUtilizationPercentage: 65
  # 订单服务
  order-service:
    replicaCount: 3
    image:
      repository: harbor.internal.com/production/order-service
      tag: v3.2.1
    ports:
      containerPort: 8082
    env:
      - name: DB_HOST
        value: "ecommerce-mysql-primary"
      - name: REDIS_HOST
        value: "ecommerce-redis-master"
      - name: KAFKA_BROKERS
        value: "kafka-0.kafka-headless:9092,kafka-1.kafka-headless:9092,kafka-2.kafka-headless:9092"
    resources:
      requests:
        cpu: 500m
        memory: 1Gi
      limits:
        cpu: 2000m
        memory: 2Gi
    autoscaling:
      enabled: true
      minReplicas: 3
      maxReplicas: 30
      targetCPUUtilizationPercentage: 60
  # 支付服务
  payment-service:
    replicaCount: 2
    image:
      repository: harbor.internal.com/production/payment-service
      tag: v2.5.0
    ports:
      containerPort: 8083
    resources:
      requests:
        cpu: 500m
        memory: 512Mi
      limits:
        cpu: 1000m
        memory: 1Gi
    autoscaling:
      enabled: true
      minReplicas: 2
      maxReplicas: 10
      targetCPUUtilizationPercentage: 60
# ========================================
# Ingress路由
# ========================================
ingress:
  enabled: true
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/proxy-body-size: "50m"
    nginx.ingress.kubernetes.io/limit-rpm: "100"
    nginx.ingress.kubernetes.io/limit-burst-multiplier: "5"
  hosts:
    - host: api.ecommerce.com
      paths:
        - path: /api/user
          pathType: Prefix
          service: user-service
          port: 8080
        - path: /api/product
          pathType: Prefix
          service: product-service
          port: 8081
        - path: /api/order
          pathType: Prefix
          service: order-service
          port: 8082
        - path: /api/payment
          pathType: Prefix
          service: payment-service
          port: 8083
  tls:
    - secretName: ecommerce-tls
      hosts:
        - api.ecommerce.com
```
---
## 七、Pod自动扩缩（HPA）
### 7.1 通用HPA配置
```yaml
# hpa-config.yaml - 为每个微服务配置HPA
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: user-service-hpa
  namespace: production
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: user-service
  minReplicas: 3
  maxReplicas: 15
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 60
      policies:
        - type: Pods
          value: 4
          periodSeconds: 60
        - type: Percent
          value: 50
          periodSeconds: 60
      selectPolicy: Max
    scaleDown:
      stabilizationWindowSeconds: 300
      policies:
        - type: Percent
          value: 25
          periodSeconds: 120
      selectPolicy: Min
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 65
    - type: Resource
      resource:
        name: memory
        target:
          type: Utilization
          averageUtilization: 80
    - type: Pods
      pods:
        metric:
          name: http_requests_per_second
        target:
          type: AverageValue
          averageValue: "1000"
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: order-service-hpa
  namespace: production
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: order-service
  minReplicas: 3
  maxReplicas: 30
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 30
      policies:
        - type: Percent
          value: 100
          periodSeconds: 60
    scaleDown:
      stabilizationWindowSeconds: 600
      policies:
        - type: Percent
          value: 10
          periodSeconds: 120
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 60
    - type: Pods
      pods:
        metric:
          name: queue_depth
        target:
          type: AverageValue
          averageValue: "50"
```
---
## 八、PodDisruptionBudget（PDB）
```yaml
# pdb-config.yaml - 保障服务在维护时可用
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: user-service-pdb
  namespace: production
spec:
  minAvailable: 2
  selector:
    matchLabels:
      app: user-service
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: order-service-pdb
  namespace: production
spec:
  minAvailable: "60%"
  selector:
    matchLabels:
      app: order-service
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: payment-service-pdb
  namespace: production
spec:
  maxUnavailable: 1
  selector:
    matchLabels:
      app: payment-service
```
---
## 九、资源配额与限制
```yaml
# resource-quota.yaml - Namespace级别资源限制
---
apiVersion: v1
kind: ResourceQuota
metadata:
  name: production-quota
  namespace: production
spec:
  hard:
    requests.cpu: "64"
    requests.memory: "128Gi"
    limits.cpu: "128"
    limits.memory: "256Gi"
    pods: "200"
    services: "50"
    persistentvolumeclaims: "30"
    configmaps: "100"
    secrets: "100"
---
apiVersion: v1
kind: LimitRange
metadata:
  name: production-limits
  namespace: production
spec:
  limits:
    - type: Container
      default:
        cpu: 500m
        memory: 512Mi
      defaultRequest:
        cpu: 100m
        memory: 128Mi
      max:
        cpu: "4"
        memory: 8Gi
      min:
        cpu: 50m
        memory: 64Mi
    - type: Pod
      max:
        cpu: "8"
        memory: 16Gi
```
---
## 十、节点标签与容忍
```bash
#!/bin/bash
# label_nodes.sh - 为节点打标签，实现调度分区
# 通用业务节点
kubectl label nodes k8s-worker-01 workload-type=general
kubectl label nodes k8s-worker-02 workload-type=general
kubectl label nodes k8s-worker-03 workload-type=general
# 高内存节点
kubectl label nodes k8s-worker-04 workload-type=memory-intensive
kubectl label nodes k8s-worker-04 node-role=stateful
# GPU节点
kubectl label nodes k8s-worker-05 workload-type=gpu
kubectl label nodes k8s-worker-05 nvidia.com/gpu=true
# 环境标签
for node in k8s-worker-{01..05}; do
  kubectl label nodes $node environment=production --overwrite
  kubectl label nodes $node team=platform --overwrite
done
echo "✅ 节点标签配置完成"
kubectl get nodes --show-labels
```
---
## 十一、etcd备份与恢复

### 11.1 基础etcd备份脚本

```bash
#!/bin/bash
# etcd_backup.sh - 定时备份etcd数据
set -euo pipefail
# [已修复] 备份频率统一为每6小时(crontab: 0 */6 * * *)
BACKUP_DIR="/data/etcd-backup"
DATE=$(date +%Y%m%d_%H%M%S)
KEEP_DAYS=7
mkdir -p ${BACKUP_DIR}
# Step 1: 检查etcd健康状态
etcdctl endpoint health --endpoints=https://127.0.0.1:2379 --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key || { echo "etcd不健康，跳过备份"; exit 1; }
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
# 添加到crontab: 每6小时备份一次
# crontab -e
# 0 */6 * * * /opt/scripts/etcd_backup.sh >> /var/log/etcd-backup.log 2>&1
```

### 11.2 生产级etcd备份增强

> **等保要求**：备份数据需加密存储、异地备份、定期验证恢复

```bash
#!/bin/bash
# etcd_backup_prod.sh - 生产级etcd备份（加密+跨区域+验证）
set -euo pipefail

BACKUP_DIR="/data/etcd-backup"
DATE=$(date +%Y%m%d_%H%M%S)
KEEP_DAYS=30  # 本地保留30天
ENCRYPT_KEY="/etc/etcd-backup/encrypt.key"  # AES-256加密密钥
REMOTE_BUCKET="s3://etcd-backups-prod-$(date +%Y%m%d)"
VERIFY_DIR="/tmp/etcd-verify"

mkdir -p ${BACKUP_DIR} ${VERIFY_DIR}

# 1. 备份etcd
echo "[1/6] 备份etcd..."
ETCDCTL_API=3 etcdctl snapshot save ${BACKUP_DIR}/etcd-snapshot-${DATE}.db \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key

# 2. 验证快照完整性
echo "[2/6] 验证快照..."
ETCDCTL_API=3 etcdctl snapshot status ${BACKUP_DIR}/etcd-snapshot-${DATE}.db --write-out=table

# 3. 加密备份文件（AES-256-CBC）
echo "[3/6] 加密备份..."
openssl enc -aes-256-cbc -salt -pbkdf2 \
  -in ${BACKUP_DIR}/etcd-snapshot-${DATE}.db \
  -out ${BACKUP_DIR}/etcd-snapshot-${DATE}.db.enc \
  -pass file:${ENCRYPT_KEY}
chmod 600 ${BACKUP_DIR}/etcd-snapshot-${DATE}.db.enc

# 4. 生成SHA256校验和（防篡改）
echo "[4/6] 生成校验和..."
sha256sum ${BACKUP_DIR}/etcd-snapshot-${DATE}.db.enc > ${BACKUP_DIR}/etcd-snapshot-${DATE}.sha256

# 5. 上传到远程存储（跨区域复制）
echo "[5/6] 上传到远程存储..."
aws s3 cp ${BACKUP_DIR}/etcd-snapshot-${DATE}.db.enc ${REMOTE_BUCKET}/
aws s3 cp ${BACKUP_DIR}/etcd-snapshot-${DATE}.sha256 ${REMOTE_BUCKET}/

# 6. 验证恢复（每月执行一次）
echo "[6/6] 月度恢复验证..."
if [ $(date +%d) -eq 1 ]; then
  echo "执行月度恢复验证..."
  # 解密快照
  openssl enc -aes-256-cbc -d -salt -pbkdf2 \
    -in ${BACKUP_DIR}/etcd-snapshot-${DATE}.db.enc \
    -out ${VERIFY_DIR}/etcd-snapshot-${DATE}.db \
    -pass file:${ENCRYPT_KEY}
  # 验证快照可读
  ETCDCTL_API=3 etcdctl snapshot status ${VERIFY_DIR}/etcd-snapshot-${DATE}.db --write-out=table
  # 清理验证目录
  rm -rf ${VERIFY_DIR}
  echo "月度恢复验证通过"
fi

# 7. 清理过期备份
find ${BACKUP_DIR} -name "etcd-snapshot-*" -mtime +${KEEP_DAYS} -delete
echo "✅ 生产级etcd备份完成"
```

> **备份策略说明**：
> - **加密**：AES-256-CBC加密，密钥存储在/etc/etcd-backup/encrypt.key（权限600）
> - **跨区域**：备份文件上传到S3跨区域存储桶，实现异地容灾
> - **防篡改**：SHA256校验和，可验证备份完整性
> - **恢复验证**：每月1日自动执行恢复验证，确保备份可用
> - **保留策略**：本地保留30天，S3保留1年
---
## 十二、集群监控集成
```bash
#!/bin/bash
# install_monitoring.sh - 安装Prometheus+Grafana监控
set -euo pipefail
echo "创建监控namespace..."
kubectl create namespace monitoring
echo "部署kube-prometheus-stack..."
echo "[注意] 如已按03-监控文档部署,请跳过本节避免资源冲突"
helm install prometheus prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --set grafana.adminPassword=${GRAFANA_ADMIN_PASSWORD} \
  --set grafana.service.type=LoadBalancer \
  --set grafana.service.loadBalancerIP=10.10.10.210 \
  --set grafana.persistence.enabled=true \
  --set grafana.persistence.size=20Gi \
  --set prometheus.prometheusSpec.retention=30d \
  --set prometheus.persistence.size=100Gi \
  --set alertmanager.persistence.size=10Gi \
  --set nodeExporter.enabled=true \
  --set kubeStateMetrics.enabled=true \
  --set prometheus.prometheusSpec.resources.requests.cpu=1 \
  --set prometheus.prometheusSpec.resources.requests.memory=4Gi
echo "等待就绪..."
kubectl -n monitoring rollout status deployment/prometheus-grafana --timeout=300s
echo "✅ 监控系统部署完成"
echo "Grafana: http://10.10.10.210 (密码请查看: kubectl -n monitoring get secret grafana-admin-credentials -o jsonpath='{.data.password}' | base64 -d)"
```
---
## 十三、EFK日志系统
> **[架构说明]** 本节EFK用于K8s集群内部日志采集,项目04的ELK用于独立应用日志。
> 两者不冲突: EFK采集K8s Pod日志,ELK采集非K8s应用日志。如已部署ELK,可跳过本节。
```bash
#!/bin/bash
# install_efk.sh - 安装EFK日志收集
set -euo pipefail
echo "部署Elasticsearch..."
# 替换为实际环境的StorageClass名称
# [私有云] 需先部署NFS或Ceph provisioner创建StorageClass
# [阿里云] 使用aliyun-disk-ssd(已预置)
helm install elasticsearch elastic/elasticsearch \
  --set persistence.storageClass=${STORAGE_CLASS:-aliyun-disk-ssd} \
  --namespace logging --create-namespace \
  --set replicas=3 \
  --set resources.requests.cpu=1 \
  --set resources.requests.memory=4Gi \
  --set persistence.enabled=true \
  --set persistence.size=200Gi
echo "部署Kibana..."
helm install kibana elastic/kibana \
  --namespace logging \
  --set elasticsearchHosts="http://elasticsearch-master:9200" \
  --set service.type=LoadBalancer \
  --set service.loadBalancerIP=10.10.10.211
echo "部署Filebeat..."
helm install filebeat elastic/filebeat \
  --namespace logging \
  --set daemonset.filebeatConfig.filebeat.yml=\
'filebeat.inputs:
- type: container
  paths:
    - /var/log/containers/*.log
  processors:
    - add_kubernetes_metadata:
        host: ${NODE_NAME}  # 注意: Helm --set传递时此变量不会被Shell展开
                          # 生产环境应使用Downward API注入: fieldRef: fieldPath: spec.nodeName
output.elasticsearch:
  hosts: ["http://elasticsearch-master:9200"]'
echo "✅ EFK日志系统部署完成"
echo "Kibana: http://10.10.10.211"
```
---
## 十四、日常巡检与自动化运维
### 14.1 日常运维命令速查
```bash
# ===== 集群状态 =====
kubectl cluster-info
kubectl get nodes -o wide
kubectl get --raw=/readyz?verbose
kubectl top nodes
# ===== Pod管理 =====
kubectl get pods -A -o wide
kubectl describe pod <pod-name> -n <namespace>
kubectl logs -f <pod-name> -n <namespace> --tail=100
kubectl exec -it <pod-name> -n <namespace> -- /bin/sh
kubectl delete pod <pod-name> -n <namespace> --grace-period=0 --force
# ===== Deployment管理 =====
kubectl rollout status deployment/<name> -n <namespace>
kubectl rollout history deployment/<name> -n <namespace>
kubectl rollout undo deployment/<name> -n <namespace> --to-revision=3
kubectl scale deployment/<name> --replicas=5 -n <namespace>
# ===== 节点维护 =====
kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data
kubectl uncordon <node-name>
kubectl cordon <node-name>
# ===== 故障排查 =====
kubectl get events -n <namespace> --sort-by='.lastTimestamp'
kubectl describe node <node-name>
kubectl get pod <pod-name> -n <namespace> -o yaml
```
### 14.2 常见故障处理
```bash
# Pod处于Pending状态
kubectl describe pod <pod-name>  # 查看Events
# 可能原因: 资源不足、PVC未绑定、节点亲和性不匹配
# Pod处于CrashLoopBackOff
kubectl logs <pod-name> --previous  # 查看上一次日志
kubectl describe pod <pod-name>     # 查看退出码
# 退出码: 1=应用错误, 137=OOMKilled, 139=段错误
# Node NotReady
journalctl -u kubelet -f          # 查看kubelet日志
systemctl status containerd       # 检查containerd
crictl pods                      # 检查运行时
# DNS解析问题
kubectl run dnstest --image=busybox --rm -it -- nslookup kubernetes.default
kubectl get cm coredns -n kube-system -o yaml
```
---
## 十五、安全加固
```yaml
# security-policies.yaml
---
# 限制容器以非root运行
apiVersion: v1
kind: Pod
metadata:
  name: security-demo
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    fsGroup: 2000
  containers:
    - name: app
      image: harbor.internal.com/production/app:latest
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop:
            - ALL
      resources:
        limits:
          cpu: "1"
          memory: 1Gi
        requests:
          cpu: 100m
          memory: 128Mi
      volumeMounts:
        - name: tmp
          mountPath: /tmp
  volumes:
    - name: tmp
      emptyDir: {}
```
---
## 十六、完整部署流程
```bash
# ===== 前置条件: SSH密钥分发 =====
# ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519
# for ip in 10.10.10.{11..13,21..25}; do ssh-copy-id -i ~/.ssh/id_ed25519.pub root@${ip}; done
# ===== 验证SSH连通性 =====
# for ip in 10.10.10.{11..13,21..25}; do ssh root@${ip} "echo OK"; done
#!/bin/bash
# [前置条件] 需要先配置SSH密钥分发:
# for ip in 10.10.10.{11..13,21..25}; do ssh-copy-id root@${ip}; done
# [错误处理] 设置set -e和错误捕获
set -euo pipefail
trap 'echo "部署失败，请检查日志"; exit 1' ERR
echo "================================================"
echo "  企业级容器云平台 - 一键部署"
echo "================================================"
echo "Step 1: 初始化所有节点..."
for ip in 10.10.10.{11,12,13,21,22,23,24,25}; do
  ssh root@${ip} 'bash -s' < init_nodes.sh &
done
wait
echo "所有节点初始化完成"
echo "Step 2: 安装HAProxy+Keepalived..."
ssh root@10.10.10.11 'bash -s' < install_haproxy_keepalived.sh
echo "负载均衡安装完成"
echo "Step 3: 初始化K8s集群(kubeadm init)..."
ssh root@10.10.10.11 'bash -s' < kubeadm_init.sh
echo "K8s集群初始化完成"
echo "Step 4: 安装Calico网络..."
ssh root@10.10.10.11 'bash -s' < install_calico.sh
echo "网络插件安装完成"
echo "Step 5: 安装MetalLB..."
ssh root@10.10.10.11 'bash -s' < install_metallb.sh
echo "MetalLB安装完成"
echo "Step 6: 部署Harbor..."
ssh root@10.10.10.31 'bash -s' < install_harbor.sh
echo "Harbor部署完成"
echo "Step 7: 安装Helm..."
ssh root@10.10.10.11 'bash -s' < install_helm.sh
echo "Helm安装完成"
echo "Step 8: 部署监控系统..."
ssh root@10.10.10.11 'bash -s' < install_monitoring.sh
echo "监控系统部署完成"
echo "Step 9: 部署日志系统..."
ssh root@10.10.10.11 'bash -s' < install_efk.sh
echo "日志系统部署完成"
echo "Step 10: 部署业务应用..."
kubectl apply -f hpa-config.yaml
kubectl apply -f pdb-config.yaml
kubectl apply -f resource-quota.yaml
echo "业务应用部署完成"
echo ""
echo "================================================"
echo "  ✅ 企业级容器云平台部署完成！"
echo "================================================"
echo "  K8s API:      https://10.10.10.100:6443"
echo "  Grafana:      http://10.10.10.210"
echo "  Grafana密码:  kubectl -n monitoring get secret grafana-admin-credentials -o jsonpath='{.data.password}' | base64 -d"
echo "  Kibana:       http://10.10.10.211"
echo "  Harbor:       https://harbor.internal.com"
echo "  Ingress LB:   10.10.10.200"
echo "================================================"
```
---
## 十七、项目文件清单
```
enterprise-container-platform/
├── scripts/
├── configs/                 # 配置文件(gitlab-ci/Dockerfile/Helm/Terraform/Ansible)
├── tests/                  # 部署验证测试
│   ├── 01_init_nodes.sh              # 节点初始化
│   ├── 02_install_haproxy_keepalived.sh  # 负载均衡
│   ├── 03_init_k8s_cluster.sh        # K8s集群初始化
│   ├── 04_join_masters.sh            # Master加入
│   ├── 05_join_workers.sh            # Worker加入
│   ├── 06_install_calico.sh          # Calico网络
│   ├── 07_install_metallb.sh         # MetalLB
│   ├── 08_install_harbor.sh          # Harbor仓库
│   ├── 09_install_helm.sh            # Helm
│   ├── 10_install_monitoring.sh      # 监控
│   ├── 11_install_efk.sh             # 日志
│   ├── 12_label_nodes.sh             # 节点标签
│   ├── etcd_backup.sh                # etcd备份
│   └── full_deploy.sh               # 一键部署
├── k8s/
│   ├── values-ecommerce.yaml         # 电商微服务Helm配置
│   ├── hpa-config.yaml               # HPA自动扩缩
│   ├── pdb-config.yaml               # Pod中断预算
│   ├── resource-quota.yaml           # 资源配额
│   └── security-policies.yaml        # 安全策略
└── README.md
```
---
## 十八、关键技术要点总结
### 18.1 高可用设计
- **API Server**: 3 Master + HAProxy + Keepalived VIP
- **etcd**: 3节点集群，快照备份每6小时
- **Worker节点**: PDB保障最少可用副本数
- **镜像仓库**: Harbor双节点主备
### 18.2 性能优化
- **containerd**: SystemdCgroup + 镜像加速
- **内核**: tcp_keepalive + somaxconn + inotify优化
- **etcd**: 4GB配额 + 自动压缩
- **Pod调度**: 节点亲和性 + 反亲和性 + 拓扑分布约束
### 18.3 安全加固
- **认证**: RBAC + ServiceAccount
- **网络**: Calico NetworkPolicy
- **镜像**: Harbor Trivy漏洞扫描
- **运行时**: 非root + 只读文件系统 + 能力限制
### 18.4 可观测性
- **监控**: Prometheus + Grafana + kube-state-metrics + node-exporter
- **日志**: EFK (Elasticsearch + Filebeat + Kibana)
- **告警**: AlertManager + 企业微信/钉钉通知
- **审计**: K8s Audit Log + etcd审计
---
> 本项目基于官方文档、技术博客和社区实践编写
> 涵盖: K8s集群搭建、Harbor、Helm、Calico、MetalLB、监控、日志、安全
> Harbor使用Docker Compose独立部署(非K8s内),生产环境也可用Helm Chart部署到K8s中。
> 适用于: 企业级容器化改造、私有PaaS平台建设
---
## 真实故障案例深度分析
### 案例1: Pod一直Pending无法调度
**故障现象**: 新部署的Pod状态一直是Pending，kubectl describe显示no nodes match
**排查过程**:
```bash
kubectl describe pod my-app-xxx -n production
# Events:
#   Warning  FailedScheduling  0/5 nodes are available: 2 Insufficient cpu, 3 Insufficient memory
kubectl top nodes
# node-01: cpu 95%, memory 88%
# node-02: cpu 92%, memory 91%
# 资源已耗尽!
```
**根因分析**: 集群资源不足，所有节点的CPU/内存请求都已满。HPA扩容后新Pod无法调度。
**解决方案**:
```bash
# 1. 水平扩容节点
kubectl scale nodepool worker-pool --replicas=8  # 注意: 此命令仅适用于阿里云ACK
# 2. 或调整资源请求
kubectl set resources deployment my-app -n production   --requests=cpu=100m,memory=128Mi   --limits=cpu=500m,memory=512Mi
# 3. 配置优先级保证关键Pod
kubectl apply -f - <<EOF
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: production-high
value: 1000000
globalDefault: false
description: "Production high priority"
EOF
```
### 案例2: ImagePullBackOff镜像拉取失败
**故障现象**: Pod状态ImagePullBackOff
**排查过程**:
```bash
kubectl describe pod my-app-xxx
# Failed to pull image "harbor.internal.com/app:v2.0": rpc error:
# code = Unknown desc = failed to pull and unpack image: pulling from host harbor.internal.com failed
# 检查节点containerd配置
crictl pull harbor.internal.com/app:v2.0
# Error: tls: failed to verify certificate
```
**解决方案**:
```bash
# 1. 将Harbor CA证书分发到所有节点
mkdir -p /etc/containerd/certs.d/harbor.internal.com
cat > /etc/containerd/certs.d/harbor.internal.com/hosts.toml << EOF
server = "https://harbor.internal.com"
[host."https://harbor.internal.com"]
  ca = "/etc/pki/ca-trust/source/anchors/harbor-ca.crt"
  skip_verify = false
EOF
# 2. 重启containerd
systemctl restart containerd
# 3. 创建ImagePullSecret
kubectl create secret docker-registry harbor-secret   --docker-server=harbor.internal.com   --docker-username=admin   --docker-password=${HARBOR_ADMIN_PASSWORD}   -n production
```
### 案例3: Service无法访问后端Pod
**故障现象**: kubectl get endpoints显示Endpoints为空
**排查过程**:
```bash
kubectl get endpoints my-service -n production
# NAME         ENDPOINTS   AGE
# my-service   <none>      1h
kubectl get pods -n production -l app=my-app --show-labels
# NAME                      READY   STATUS    LABELS
# my-app-7d8f9b6c4-xxx      1/1     Running   app=my-app-v2  # 标签是v2不是v1!
kubectl get service my-service -n production -o yaml | grep selector
# selector:
#   app: my-app-v1  # selector不匹配!
```
**解决方案**:
```yaml
# 修正Service selector
apiVersion: v1
kind: Service
metadata:
  name: my-service
  namespace: production
spec:
  selector:
    app: my-app  # 修正为my-app
  ports:
  - port: 80
    targetPort: 8080
```
### 案例4: PVC挂载失败导致Pod CrashLoopBackOff
**故障现象**: Pod启动后反复重启
**排查过程**:
```bash
kubectl describe pod my-app-xxx -n production
# Warning  FailedMount  Unable to attach or mount volumes: timed out waiting for the condition
# pvc "data-my-app-0" is being deleted
kubectl get pvc data-my-app-0 -n production
# STATUS: Terminating
```
**解决方案**:
```bash
# 1. 取消PVC删除
kubectl patch pvc data-my-app-0 -n production -p '{"metadata":{"finalizers":null}}'
# 2. 或配置storageClass reclaimPolicy: Retain
kubectl patch storageclass fast-ssd -p '{"reclaimPolicy":"Retain"}'
# 3. 预防: 使用StatefulSet时确保PVC不会被误删
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: data-my-app-0
  namespace: production
  finalizers:
  - kubernetes.io/pvc-protection
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: fast-ssd
  resources:
    requests:
      storage: 100Gi
EOF
```
### 案例5: Node节点NotReady
**故障现象**: kubectl get nodes显示某节点NotReady
**排查过程**:
```bash
kubectl describe node node-03
# Conditions:
#   Type             Status  Reason
#   MemoryPressure   True    KubeletHasMemoryEviction
#   DiskPressure     True    KubeletHasDiskEviction
# 节点磁盘满
ssh node-03 "df -h /var/lib/kubelet"
# /dev/vda1  100G   98G  2G  98% /var/lib/kubelet
```
**解决方案**:
```bash
# 1. 清理节点磁盘
ssh node-03 "crictl rmi --prune"
ssh node-03 "rm -rf /var/lib/kubelet/pods/*/volumes/kubernetes.io~empty-dir/*"
# 2. 配置kubelet磁盘回收策略
cat > /etc/kubernetes/kubelet-config.yaml << EOF
evictionHard:
  memory.available: "500Mi"
  nodefs.available: "10%"
  imagefs.available: "15%"
evictionMinimumReclaim:
  nodefs.available: "5%"
  imagefs.available: "10%"
EOF
systemctl restart kubelet
# 3. 节点恢复
kubectl uncordon node-03
```
### 案例6: DNS解析失败导致服务间通信中断
**故障现象**: Pod内curl http://my-service返回"Could not resolve host"
**排查过程**:
```bash
# 检查CoreDNS状态
kubectl get pods -n kube-system -l k8s-app=kube-dns
# coredns-xxx   0/1     CrashLoopBackOff
kubectl logs coredns-xxx -n kube-system
# plugin/configuration: Corefile:2: not a valid configuration token
# 检查ConfigMap
kubectl get configmap coredns -n kube-system -o yaml
# 发现: Corefile语法错误
```
**解决方案**:
```yaml
# 修复CoreDNS配置
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns
  namespace: kube-system
data:
  Corefile: |
    .:53 {
        errors
        health {
            lameduck 5s
        }
        ready
        kubernetes cluster.local in-addr.arpa ip6.arpa {
            pods insecure
            fallthrough in-addr.arpa ip6.arpa
            ttl 30
        }
        prometheus :9153
        forward . /etc/resolv.conf
        cache 30
        loop
        reload
        loadbalance
    }
```
### 案例7: ConfigMap热更新不生效
**故障现象**: 修改了ConfigMap但Pod中配置未更新
**排查过程**:
```bash
kubectl get configmap my-config -n production -o yaml | grep resourceVersion
# resourceVersion: "12345"
kubectl get deployment my-app -n production -o yaml | grep -A5 volumeMounts
# 发现: 使用了subPath挂载，不会自动更新
# volumeMounts:
#   - name: config
#     mountPath: /etc/config/nginx.conf
#     subPath: nginx.conf  # subPath不会自动更新!
```
**解决方案**:
```bash
# 1. 移除subPath，使用目录挂载
kubectl patch deployment my-app -n production -p '{
  "spec": {
    "template": {
      "spec": {
        "containers": [{
          "name": "my-app",
          "volumeMounts": [{
            "name": "config",
            "mountPath": "/etc/config"
          }]
        }]
      }
    }
  }
}'
# 2. 或使用Reloader自动重启
kubectl apply -f - <<EOF
apiVersion: stakater.com/v1
kind: Reloader
metadata:
  name: my-app-reloader
spec:
  reloadStrategy: annotation
  resource:
    kind: deployment
    name: my-app
    namespace: production
  configmaps:
    - name: my-config
      namespaces: [production]
EOF
```
### 案例8: HPA不扩容导致服务过载
**故障现象**: CPU使用率已超过80%但HPA没有扩容
**排查过程**:
```bash
kubectl get hpa my-app -n production
# NAME     REFERENCE              TARGETS         MINPODS   MAXPODS   REPLICAS
# my-app   Deployment/my-app      85%/50%         3         10        3
# TARGETS显示85%但副本数没变!
kubectl describe hpa my-app
# Warning  FailedGetMetric  unable to fetch metrics: the server could not find the requested resource
# 检查metrics-server
kubectl get pods -n kube-system | grep metrics
# metrics-server-xxx   0/1     CrashLoopBackOff
```
**解决方案**:
```bash
# 1. 修复metrics-server
kubectl logs metrics-server-xxx -n kube-system
# Error: unable to read a client certificate from /etc/kubernetes/pki/sa.key
# 重新部署metrics-server
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
# 2. 或安装Prometheus Adapter作为metrics源
helm install prometheus-adapter prometheus-community/prometheus-adapter   --namespace monitoring   --set prometheus.url=http://prometheus.monitoring   --set prometheus.port=9090
# 3. 调整HPA配置
kubectl patch hpa my-app -n production -p '{
  "spec": {
    "minReplicas": 3,
    "maxReplicas": 20,
    "behavior": {
      "scaleUp": {
        "stabilizationWindowSeconds": 60,
        "policies": [{"type": "Percent", "value": 100, "periodSeconds": 60}]
      },
      "scaleDown": {
        "stabilizationWindowSeconds": 300,
        "policies": [{"type": "Percent", "value": 10, "periodSeconds": 60}]
      }
    }
  }
}'
```
---
## 高级性能调优参数
### kubelet参数调优
```yaml
# /var/lib/kubelet/config.yaml
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
# 资源管理
maxPods: 220              # 单节点最大Pod数(默认110)
podsPerCore: 30           # 每核最大Pod数
evictionHard:
  memory.available: "500Mi"
  nodefs.available: "10%"
  imagefs.available: "15%"
# 容器运行时
serializeImagePulls: false  # 并行拉取镜像
maxParallelImagePulls: 5
# 健康检查
syncFrequency: "10s"
fileCheckFrequency: "20s"
httpCheckFrequency: "20s"
```
### etcd调优
```yaml
# etcd配置
etcd:
  extraArgs:
    # 性能
    quota-backend-bytes: "4294967296"  # 4GB，etcd默认2GB，最大8GB
    auto-compaction-mode: "periodic"
    auto-compaction-retention: "8h"
    # 预编译
    experimental-enable-lease-checkpoint: "true"
    # 快照
    snapshot-count: "10000"
    # 心跳
    heartbeat-interval: "100"
    election-timeout: "1000"
```
### API Server限流
```yaml
# kube-apiserver配置
apiServer:
  extraArgs:
    max-requests-inflight: "400"        # 只读请求
    max-mutating-requests-inflight: "200" # 变更请求
    event-ttl: "720h"  # 统一为30天(与主配置一致)
    audit-log-maxage: "30"
    audit-log-maxbackup: "10"
    audit-log-maxsize: "100"
```
### Calico网络优化
```yaml
# calico-node配置
apiVersion: projectcalico.org/v3
kind: Node
metadata:
  name: node-01
spec:
  bgp:
    asNumber: 64512
    nodeMeshMaxRestartTime: 120s
  # Felix配置
  config:
    # 网络性能
    tcpTimeoutShort: "10s"
    tcpTimeoutMedium: "30s"
    tcpTimeoutLong: "120s"
    tcpInboundRestart: "10s"
    tcpEstablishedTimeout: "120s"
    # 连接追踪
    conntrackMax: "1048576"
    conntrackRateLimit: "200"
    # BFD
    felixBPFConnectTimeLoadBalancingEnabled: true
```
---
## 双机房灾备方案
### 架构设计
```
机房A (主): etcd x3 + Master x3 + Worker x6 + Harbor + Prometheus
           │ 跨机房复制
机房B (备): etcd x3 + Master x3 + Worker x6 + Harbor + Prometheus
DNS: app.example.com → 机房A优先，机房B备用
监控: 双机房独立采集，集中告警
```
### etcd备份恢复
> **etcd备份脚本见第十一节** (etcd_backup.sh)，此处仅展示恢复流程。
```bash
#!/bin/bash
# etcd_restore.sh - etcd恢复(从备份快照恢复)
set -euo pipefail
BACKUP_FILE=$1
if [ -z "$BACKUP_FILE" ]; then
  echo "用法: $0 <etcd-snapshot-file.db>"
  echo "示例: $0 /data/etcd-backup/etcd-snapshot-20260506_120000.db"
  exit 1
fi
# 1. 停止etcd服务
systemctl stop etcd
# 2. 备份当前数据目录
mv /var/lib/etcd /var/lib/etcd.bak.$(date +%Y%m%d%H%M%S)
# 3. 从快照恢复
ETCDCTL_API=3 etcdctl snapshot restore "$BACKUP_FILE" \
  --data-dir=/var/lib/etcd \
  --name=$(hostname -s) \
  --initial-cluster="etcd-0=https://10.10.10.11:2380,etcd-1=https://10.10.10.12:2380,etcd-2=https://10.10.10.13:2380" \
  --initial-advertise-peer-urls=https://$(hostname -i):2380 \
  --initial-cluster-token=etcd-cluster
# 4. 启动etcd
systemctl start etcd
# 5. 验证恢复结果
etcdctl endpoint health --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key
echo "✅ etcd恢复完成"
```
### 故障切换SOP
```bash
#!/bin/bash
# disaster_recovery.sh
# 机房A不可用时切换到机房B
echo "===== 灾备切换开始 ====="
# 1. 确认机房A不可用
kubectl --context=dc-a get nodes 2>/dev/null
if [ $? -eq 0 ]; then
    echo "机房A仍然可用，请确认是否继续"
    exit 1
fi
# 2. 在机房B的Master节点上修改apiserver启动参数(Static Pod)
# [注意] kube-apiserver是Static Pod，不是Deployment，不能用kubectl patch
# 需要修改 /etc/kubernetes/manifests/kube-apiserver.yaml
# 在机房B的所有Master节点上执行:
for master in dc-b-master-01 dc-b-master-02 dc-b-master-03; do
  ssh root@${master} bash << 'PATCH_EOF'
    # 备份原配置
    cp /etc/kubernetes/manifests/kube-apiserver.yaml /etc/kubernetes/manifests/kube-apiserver.yaml.bak
    # 修改authorization-mode为RBAC (移除AlwaysAllow)
    sed -i 's/--authorization-mode=Node,RBAC,AlwaysAllow/--authorization-mode=Node,RBAC/' \
      /etc/kubernetes/manifests/kube-apiserver.yaml
    echo "已修改 ${master} apiserver authorization-mode"
PATCH_EOF
done
# 3. 更新DNS指向机房B
# aws route53 change-resource-record-sets ...
# 4. 验证服务可用
kubectl --context=dc-b get pods -A | grep -v Running
echo "===== 灾备切换完成 ====="
```
---
## 详细成本估算
| 项目 | 自建(裸金属) | 阿里云ACK | AWS EKS |
|------|------------|----------|---------|
| Master节点(3x4C16G) | ¥12,000/月 | ¥8,000/月 | $1,000/月 |
| Worker节点(6x8C32G) | ¥54,000/月 | ¥45,000/月 | $5,500/月 |
| Harbor(2x4C8G) | ¥4,000/月 | ¥2,000/月 | $250/月 |
| 监控(Prometheus+Grafana) | ¥3,000/月 | ¥2,000/月 | $200/月 |
| 网络(1Gbps) | ¥5,000/月 | ¥3,000/月 | $300/月 |
| 运维人力(0.5人) | ¥10,000/月 | ¥3,000/月 | $300/月 |
| **月度总计** | **¥88,000** | **¥63,000** | **$7,550 (¥54,000)** |
三年TCO: 自建¥3,168,000 vs 阿里云¥2,268,000 (省29%) vs AWS ¥1,944,000 (省39%)
---
## 全链路监控告警
```yaml
groups:
  - name: kubernetes
    rules:
      - alert: PodCrashLooping
        expr: rate(kube_pod_container_status_restarts_total[15m]) > 0
        for: 5m
        labels: { severity: warning }
      - alert: PodNotReady
        expr: kube_pod_status_ready{condition="false"} == 1
        for: 5m
        labels: { severity: warning }
      - alert: NodeNotReady
        expr: kube_node_status_condition{condition="Ready",status="true"} == 0
        for: 2m
        labels: { severity: critical }
      - alert: PersistentVolumeFillingUp
        expr: predict_linear(kubelet_volume_stats_available_bytes[6h], 60*60*24*4) < 0
        for: 10m
        labels: { severity: warning }
      - alert: DeploymentReplicasMismatch
        expr: kube_deployment_spec_replicas != kube_deployment_status_available_replicas
        for: 10m
        labels: { severity: warning }
      - alert: HighCPUUsage
        expr: 1 - (sum(rate(container_cpu_usage_seconds_total[5m])) by (node) / sum(kube_node_status_allocatable{resource="cpu"}) by (node)) < 0.1
        for: 10m
        labels: { severity: warning }
```
---
## 完整运维SOP
### 日常巡检
```bash
#!/bin/bash
echo "===== K8s集群巡检 ====="
# 节点状态
kubectl get nodes -o wide
# 组件状态
kubectl get --raw=/readyz?verbose
# 系统Pod
kubectl get pods -n kube-system
# 异常Pod
kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded
# PVC状态
kubectl get pvc -A | grep -v Bound
# 资源使用
kubectl top nodes
kubectl top pods -A --sort-by=cpu | head -20
```
### etcd备份SOP
> **完整脚本见第十一节** (etcd_backup.sh)，此处仅展示crontab配置。
```bash
# 每6小时自动备份 (crontab: 0 */6 * * *)
# 0 */6 * * * /opt/scripts/etcd_backup.sh >> /var/log/etcd-backup.log 2>&1
```
### 版本升级SOP
```bash
# 1. 备份etcd
# 2. 升级Master节点
# 3. 验证集群状态
# 4. 升级Worker节点(kubectl drain + uncordon)
# 5. 验证应用正常
```
---
## 踩坑记录
### Q1: kubeadm init卡在[wait-control-plane]
**原因**: containerd未正确配置SystemdCgroup
**解决**: 确认 /etc/containerd/config.toml 中 SystemdCgroup = true
### Q2: Calico BGP模式下跨节点Pod不通
**原因**: 安全组/防火墙未放行BGP端口179
**解决**: iptables -A INPUT -p tcp --dport 179 -j ACCEPT
### Q3: Harbor推送镜像报x509 certificate signed by unknown authority
**原因**: 节点未信任Harbor CA证书
**解决**: 将Harbor CA证书分发到所有节点的 /etc/containerd/certs.d/ 目录
### Q4: MetalLB分配的External IP无法访问
**原因**: 节点间二层网络不通(跨子网)
**解决**: 改用L2模式或配置BGP peering
### Q5: HPA不扩容但CPU已超阈值
**原因**: metrics-server未正确部署
**解决**: 检查metrics-server Pod状态，确认--kubelet-insecure-tls参数
## etcd备份与恢复
> **etcd备份脚本见第十一节** (etcd_backup.sh)，此处仅展示恢复流程。
### crontab配置
```bash
# 每6小时执行etcd备份 (与第十一节统一)
0 */6 * * * /opt/scripts/etcd-backup.sh >> /var/log/etcd-backup.log 2>&1
```
### 恢复步骤
```bash
# 1. 停止所有Master节点的etcd
systemctl stop etcd
# 2. 恢复etcd数据
ETCDCTL_API=3 etcdctl snapshot restore /data/etcd-backup/etcd-snapshot-YYYYMMDD_HHMMSS.db \
  --data-dir=/var/lib/etcd-restore \
  --name=<etcd-member-name> \
  --initial-cluster=<etcd-cluster> \
  --initial-advertise-peer-urls=https://<ip>:2380
# 3. 替换数据目录
mv /var/lib/etcd /var/lib/etcd.bak
mv /var/lib/etcd-restore /var/lib/etcd
# 4. 重启etcd
systemctl start etcd
```
> 涵盖: K8s集群搭建、Harbor、Helm、Calico、MetalLB、监控、日志、安全
> Harbor使用Docker Compose独立部署(非K8s内),生产环境也可用Helm Chart部署到K8s中。
> 适用于: 企业级容器化改造、私有PaaS平台建设
