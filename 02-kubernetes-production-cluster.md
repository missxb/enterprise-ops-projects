# 企业级项目02: Kubernetes 生产集群搭建与应用部署

## 📋 项目概述

完整的Kubernetes生产集群搭建方案，包含多节点集群、监控、日志、存储、CI/CD全流程。

**架构**: 1 Master + 3 Worker | Calico网络 | MetalLB负载 | Prometheus监控

---

## 🏗️ 架构图

```
┌─────────────────────────────────────────────────────────────────┐
│                     Kubernetes 集群架构                          │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐            │
│  │  Master-1   │  │  Master-2   │  │  Master-3   │            │
│  │  4C 8G      │  │  4C 8G      │  │  4C 8G      │            │
│  │  API Server │  │  API Server │  │  API Server │            │
│  │  etcd       │  │  etcd       │  │  etcd       │            │
│  │  Scheduler  │  │  Scheduler  │  │  Scheduler  │            │
│  │  Controller │  │  Controller │  │  Controller │            │
│  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘            │
│         │                │                │                     │
│  ═══════╪════════════════╪════════════════╪═══════════════      │
│         │          Calico 网络层           │                     │
│  ═══════╪════════════════╪════════════════╪═══════════════      │
│         │                │                │                     │
│  ┌──────▼──────┐  ┌──────▼──────┐  ┌──────▼──────┐            │
│  │  Worker-1   │  │  Worker-2   │  │  Worker-3   │            │
│  │  8C 16G     │  │  8C 16G     │  │  8C 16G     │            │
│  │  kubelet    │  │  kubelet    │  │  kubelet    │            │
│  │  kube-proxy │  │  kube-proxy │  │  kube-proxy │            │
│  │  Container  │  │  Container  │  │  Container  │            │
│  │  Runtime    │  │  Runtime    │  │  Runtime    │            │
│  └─────────────┘  └─────────────┘  └─────────────┘            │
│                                                                 │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │                    基础设施层                              │   │
│  │  MetalLB    │  NFS Storage  │  Ingress NGINX            │   │
│  │  (LoadBal)  │  (PV/PVC)     │  (反向代理)                │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                 │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │                    监控与日志                              │   │
│  │  Prometheus │  Grafana  │  AlertManager │  Loki          │   │
│  └─────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

---

## 📁 项目文件结构

```
k8s-production-cluster/
├── 01-init-all-nodes.sh           # 所有节点初始化脚本
├── 02-init-master.sh              # Master节点初始化
├── 03-join-workers.sh             # Worker节点加入集群
├── 04-install-calico.sh           # Calico网络插件
├── 05-install-metallb.sh          # MetalLB负载均衡
├── 06-install-ingress.sh          # NGINX Ingress Controller
├── 07-install-nfs-storage.sh      # NFS存储配置
├── 08-install-monitoring.sh       # Prometheus + Grafana监控
├── 09-install-logging.sh          # Loki + Promtail日志
├── 10-deploy-application.sh       # 示例应用部署
├── manifests/
│   ├── namespace.yaml             # 命名空间
│   ├── resource-quota.yaml        # 资源配额
│   ├── network-policy.yaml        # 网络策略
│   ├── rbac.yaml                  # RBAC权限
│   ├── app-deployment.yaml        # 应用部署
│   ├── app-service.yaml           # 服务
│   ├── app-ingress.yaml           # Ingress规则
│   ├── app-hpa.yaml               # 自动扩缩容
│   ├── app-pdb.yaml               # Pod中断预算
│   ├── app-configmap.yaml         # 配置
│   └── app-secret.yaml            # 密钥
├── kubeadm-config.yaml            # kubeadm配置
└── README.md                      # 本文档
```

---

## 🚀 部署步骤

### 第一步: 所有节点初始化

```bash
# 在所有节点执行
bash 01-init-all-nodes.sh
```

**01-init-all-nodes.sh**:
```bash
#!/bin/bash
# ============================================
# 所有Kubernetes节点初始化
# 适用于: Ubuntu 22.04 / Debian 12
# ============================================

set -euo pipefail

echo "=========================================="
echo "  Kubernetes 节点初始化"
echo "=========================================="

# 1. 设置主机名（在每个节点修改）
# hostnamectl set-hostname k8s-master-1  # Master节点
# hostnamectl set-hostname k8s-worker-1  # Worker节点

# 2. 禁用Swap
echo "[1/6] 禁用Swap..."
swapoff -a
sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

# 3. 加载内核模块
echo "[2/6] 加载内核模块..."
cat <<EOF | tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

# 4. 配置内核参数
echo "[3/6] 配置内核参数..."
cat <<EOF | tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
net.ipv4.tcp_keepalive_time         = 600
net.ipv4.tcp_keepalive_intvl        = 30
net.ipv4.tcp_keepalive_probes       = 5
fs.inotify.max_user_watches         = 524288
fs.inotify.max_user_instances       = 512
EOF
sysctl --system

# 5. 安装containerd
echo "[4/6] 安装containerd..."
apt-get update
apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release

# 添加Docker GPG密钥
mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
    gpg --dearmor -o /etc/apt/keyrings/docker.gpg

# 添加Docker仓库
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | \
    tee /etc/apt/sources.list.d/docker.list > /dev/null

apt-get update
apt-get install -y containerd.io

# 配置containerd
mkdir -p /etc/containerd
containerd config default | tee /etc/containerd/config.toml

# 启用SystemdCgroup
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

# 使用阿里云镜像（国内加速）
sed -i 's|sandbox_image = "registry.k8s.io/pause:.*"|sandbox_image = "registry.aliyuncs.com/google_containers/pause:3.9"|' /etc/containerd/config.toml

systemctl restart containerd
systemctl enable containerd

# 6. 安装kubeadm, kubelet, kubectl
echo "[5/6] 安装Kubernetes工具..."
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.29/deb/Release.key | \
    gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
    https://pkgs.k8s.io/core:/stable:/v1.29/deb/ /" | \
    tee /etc/apt/sources.list.d/kubernetes.list

apt-get update
apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl

# 7. 配置crictl
echo "[6/6] 配置crictl..."
cat <<EOF | tee /etc/crictl.yaml
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
EOF

echo ""
echo "✅ 所有节点初始化完成!"
echo "请确保所有节点已配置 /etc/hosts:"
echo "192.168.1.10  k8s-master-1"
echo "192.168.1.11  k8s-master-2"
echo "192.168.1.12  k8s-master-3"
echo "192.168.1.21  k8s-worker-1"
echo "192.168.1.22  k8s-worker-2"
echo "192.168.1.23  k8s-worker-3"
```

### 第二步: 初始化Master节点

```bash
# 仅在Master-1执行
bash 02-init-master.sh
```

**02-init-master.sh**:
```bash
#!/bin/bash
# ============================================
# Kubernetes Master节点初始化
# ============================================

set -euo pipefail

echo "=========================================="
echo "  Kubernetes Master 初始化"
echo "=========================================="

# kubeadm配置文件
cat <<EOF | tee kubeadm-config.yaml
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
kubernetesVersion: v1.29.0
controlPlaneEndpoint: "192.168.1.100:6443"
networking:
  podSubnet: "10.244.0.0/16"
  serviceSubnet: "10.96.0.0/12"
  dnsDomain: "cluster.local"
apiServer:
  extraArgs:
    service-node-port-range: "30000-32767"
    enable-admission-plugins: "NodeRestriction,PodSecurityPolicy"
etcd:
  local:
    dataDir: /var/lib/etcd
    extraArgs:
      heartbeat-interval: "500"
      election-timeout: "2500"
controllerManager:
  extraArgs:
    terminated-pod-gc-threshold: "100"
scheduler:
  extraArgs:
    profiling: "false"
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: InitConfiguration
nodeRegistration:
  criSocket: unix:///var/run/containerd/containerd.sock
  imagePullPolicy: IfNotPresent
localAPIEndpoint:
  advertiseAddress: "192.168.1.10"
  bindPort: 6443
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
containerRuntimeEndpoint: unix:///var/run/containerd/containerd.sock
failSwapOn: true
maxPods: 220
systemReserved:
  cpu: "500m"
  memory: "1Gi"
kubeReserved:
  cpu: "500m"
  memory: "1Gi"
evictionHard:
  memory.available: "200Mi"
  nodefs.available: "10%"
EOF

# 初始化集群
echo "[1/4] 初始化Kubernetes集群..."
kubeadm init --config kubeadm-config.yaml --upload-certs | tee /tmp/kubeadm-init.log

# 配置kubectl
echo "[2/4] 配置kubectl..."
mkdir -p $HOME/.kube
cp -f /etc/kubernetes/admin.conf $HOME/.kube/config
chown $(id -u):$(id -g) $HOME/.kube/config

# 保存加入命令
echo "[3/4] 保存加入命令..."
grep -A2 "kubeadm join" /tmp/kubeadm-init.log > /tmp/join-command.sh
chmod +x /tmp/join-command.sh

# 保存控制平面加入命令
kubeadm init phase upload-certs --upload-certs 2>/dev/null | grep -E "^[0-9a-f]{64}$" | \
    awk '{print "kubeadm join 192.168.1.100:6443 --token TOKEN --discovery-token-ca-cert-hash sha256:HASH --control-plane --certificate-key "$1}' > /tmp/control-plane-join.sh

echo ""
echo "✅ Master初始化完成!"
echo ""
echo "📌 请保存以下信息:"
echo "   Worker加入命令: cat /tmp/join-command.sh"
echo "   控制平面加入命令: cat /tmp/control-plane-join.sh"
echo ""
echo "⏳ 等待所有Master加入后，安装Calico网络插件"
```

### 第三步: Worker节点加入

```bash
# 在每个Worker节点执行
bash 03-join-workers.sh
```

**03-join-workers.sh**:
```bash
#!/bin/bash
# ============================================
# Worker节点加入集群
# ============================================

set -euo pipefail

echo "=========================================="
echo "  Worker 节点加入集群"
echo "=========================================="

# 从Master节点复制join命令
echo "请从Master-1节点复制join命令:"
echo "  cat /tmp/join-command.sh"
echo ""
echo "然后在本节点执行输出的命令"
echo ""
echo "示例:"
echo "  kubeadm join 192.168.1.100:6443 \\"
echo "    --token abc123.xyz456 \\"
echo "    --discovery-token-ca-cert-hash sha256:xxxx"
echo ""

# 如果已有join命令
if [ -f /tmp/join-command.sh ]; then
    read -p "是否执行join命令? (y/n): " confirm
    if [ "$confirm" = "y" ]; then
        bash /tmp/join-command.sh
        echo "✅ Worker节点加入成功!"
    fi
fi
```

### 第四步: 安装Calico网络

```bash
# 仅在Master-1执行
bash 04-install-calico.sh
```

**04-install-calico.sh**:
```bash
#!/bin/bash
# ============================================
# Calico 网络插件安装
# ============================================

set -euo pipefail

echo "=========================================="
echo "  安装 Calico 网络插件"
echo "=========================================="

# 安装Calico operator
echo "[1/4] 安装Calico Operator..."
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.0/manifests/tigera-operator.yaml

# 配置Calico
echo "[2/4] 配置Calico..."
cat <<EOF | kubectl apply -f -
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
      encapsulation: VXLANCrossSubnet
      natOutgoing: Enabled
      nodeSelector: all()
---
apiVersion: operator.tigera.io/v1
kind: APIServer
metadata:
  name: default
spec: {}
EOF

# 等待Calico就绪
echo "[3/4] 等待Calico Pod就绪..."
kubectl -n calico-system wait --for=condition=Ready pod --all --timeout=300s

# 验证
echo "[4/4] 验证网络插件..."
kubectl get pods -n calico-system
kubectl get ippool -o wide

echo ""
echo "✅ Calico安装完成!"
echo ""
echo "📌 验证命令:"
echo "   kubectl get nodes"
echo "   kubectl get pods -n calico-system"
echo "   kubectl run test --image=nginx --rm -it -- /bin/bash"
```

### 第五步: 安装MetalLB

```bash
bash 05-install-metallb.sh
```

**05-install-metallb.sh**:
```bash
#!/bin/bash
# ============================================
# MetalLB 负载均衡安装
# ============================================

set -euo pipefail

echo "=========================================="
echo "  安装 MetalLB 负载均衡"
echo "=========================================="

# 安装MetalLB
echo "[1/3] 安装MetalLB..."
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.13.12/config/manifests/metallb-native.yaml

# 等待就绪
echo "[2/3] 等待MetalLB就绪..."
kubectl -n metallb-system wait --for=condition=Ready pod --all --timeout=300s

# 配置IP地址池（根据你的网络环境修改）
echo "[3/3] 配置IP地址池..."
cat <<EOF | kubectl apply -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: default-pool
  namespace: metallb-system
spec:
  addresses:
  - 192.168.1.200-192.168.1.250   # 修改为你的IP范围
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: default
  namespace: metallb-system
spec:
  ipAddressPools:
  - default-pool
EOF

echo ""
echo "✅ MetalLB安装完成!"
echo ""
echo "📌 测试LoadBalancer:"
echo "   kubectl run nginx-test --image=nginx --port=80"
echo "   kubectl expose pod nginx-test --type=LoadBalancer --port=80"
echo "   kubectl get svc nginx-test  # 查看EXTERNAL-IP"
```

### 第六步: 安装NGINX Ingress

```bash
bash 06-install-ingress.sh
```

**06-install-ingress.sh**:
```bash
#!/bin/bash
# ============================================
# NGINX Ingress Controller 安装
# ============================================

set -euo pipefail

echo "=========================================="
echo "  安装 NGINX Ingress Controller"
echo "=========================================="

# 安装Ingress Controller
echo "[1/3] 安装NGINX Ingress Controller..."
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update

helm install ingress-nginx ingress-nginx/ingress-nginx \
    --namespace ingress-nginx \
    --create-namespace \
    --set controller.replicaCount=2 \
    --set controller.service.type=LoadBalancer \
    --set controller.resources.requests.cpu=200m \
    --set controller.resources.requests.memory=256Mi \
    --set controller.resources.limits.cpu=1000m \
    --set controller.resources.limits.memory=1Gi \
    --set controller.metrics.enabled=true \
    --set controller.metrics.serviceMonitor.enabled=false \
    --set controller.config.use-forwarded-headers="true" \
    --set controller.config.enable-real-ip="true" \
    --set controller.config.log-format-upstream='\$remote_addr - \$remote_user [\$time_local] "\$request" \$status \$body_bytes_sent "\$http_referer" "\$http_user_agent" \$request_length \$request_time [\$proxy_upstream_name] [\$proxy_alternative_upstream_name] \$upstream_addr \$upstream_response_length \$upstream_response_time \$upstream_status \$req_id'

# 等待就绪
echo "[2/3] 等待Ingress就绪..."
kubectl -n ingress-nginx wait --for=condition=Ready pod --all --timeout=300s

# 验证
echo "[3/3] 验证安装..."
kubectl -n ingress-nginx get pods
kubectl -n ingress-nginx get svc

echo ""
echo "✅ NGINX Ingress安装完成!"
echo ""
echo "📌 获取Ingress Controller外部IP:"
echo "   kubectl -n ingress-nginx get svc ingress-nginx-controller"
echo ""
echo "📌 配置DNS: 将你的域名A记录指向上面的EXTERNAL-IP"
```

### 第七步: 安装NFS存储

```bash
bash 07-install-nfs-storage.sh
```

**07-install-nfs-storage.sh**:
```bash
#!/bin/bash
# ============================================
# NFS 持久化存储配置
# ============================================

set -euo pipefail

echo "=========================================="
echo "  配置 NFS 持久化存储"
echo "=========================================="

NFS_SERVER="192.168.1.50"    # 修改为你的NFS服务器
NFS_PATH="/data/k8s"         # NFS共享路径

# 在NFS服务器上创建共享目录（提前执行）
# mkdir -p /data/k8s/{default,monitoring,logging}
# chmod -R 777 /data/k8s

# 创建StorageClass
echo "[1/4] 创建StorageClass..."
cat <<EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: nfs-client
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: k8s-sigs.io/nfs-subdir-external-provisioner
parameters:
  server: ${NFS_SERVER}
  path: ${NFS_PATH}
  archiveOnDelete: "true"
  archiveBackupTimeout: "60"
reclaimPolicy: Retain
volumeBindingMode: Immediate
allowVolumeExpansion: true
mountOptions:
  - hard
  - nfsvers=4.1
EOF

# 安装NFS Provisioner
echo "[2/4] 安装NFS Provisioner..."
helm repo add nfs-subdir-external-provisioner https://kubernetes-sigs.github.io/nfs-subdir-external-provisioner
helm repo update

helm install nfs-provisioner nfs-subdir-external-provisioner/nfs-subdir-external-provisioner \
    --namespace kube-system \
    --set nfs.server=${NFS_SERVER} \
    --set nfs.path=${NFS_PATH} \
    --set storageClass.name=nfs-client \
    --set storageClass.defaultClass=true \
    --set storageClass.reclaimPolicy=Retain

# 创建测试PVC
echo "[3/4] 创建测试PVC..."
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-pvc
  namespace: default
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: nfs-client
  resources:
    requests:
      storage: 1Gi
EOF

# 验证
echo "[4/4] 验证存储..."
kubectl get storageclass
kubectl get pvc test-pvc

echo ""
echo "✅ NFS存储配置完成!"
echo ""
echo "📌 使用方法:"
echo "   storageClassName: nfs-client  # 在PVC中指定"
```

### 第八步: 安装监控系统

```bash
bash 08-install-monitoring.sh
```

**08-install-monitoring.sh**:
```bash
#!/bin/bash
# ============================================
# Prometheus + Grafana 监控系统安装
# ============================================

set -euo pipefail

echo "=========================================="
echo "  安装 Prometheus + Grafana 监控系统"
echo "=========================================="

# 创建命名空间
kubectl create namespace monitoring

# 安装kube-prometheus-stack
echo "[1/4] 安装kube-prometheus-stack..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm install prometheus prometheus-community/kube-prometheus-stack \
    --namespace monitoring \
    --set grafana.adminPassword=Admin@2024 \
    --set grafana.service.type=LoadBalancer \
    --set grafana.persistence.enabled=true \
    --set grafana.persistence.storageClassName=nfs-client \
    --set grafana.persistence.size=10Gi \
    --set prometheus.prometheusSpec.retention=30d \
    --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.storageClassName=nfs-client \
    --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage=50Gi \
    --set prometheus.prometheusSpec.resources.requests.cpu=500m \
    --set prometheus.prometheusSpec.resources.requests.memory=2Gi \
    --set alertmanager.alertmanagerSpec.retention=120h \
    --set alertmanager.alertmanagerSpec.storage.volumeClaimTemplate.spec.storageClassName=nfs-client \
    --set alertmanager.alertmanagerSpec.storage.volumeClaimTemplate.spec.resources.requests.storage=10Gi

# 等待就绪
echo "[2/4] 等待监控组件就绪..."
kubectl -n monitoring wait --for=condition=Ready pod --l app.kubernetes.io/name=grafana --timeout=300s
kubectl -n monitoring wait --for=condition=Ready pod --l app.kubernetes.io/name=prometheus --timeout=300s

# 配置告警规则
echo "[3/4] 配置自定义告警规则..."
cat <<EOF | kubectl apply -f -
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: custom-alerts
  namespace: monitoring
  labels:
    prometheus: kube-prometheus
    role: alert-rules
spec:
  groups:
  - name: node-alerts
    rules:
    - alert: NodeHighCPU
      expr: 100 - (avg by(instance) (irate(node_cpu_seconds_total{mode="idle"}[5m])) * 100) > 85
      for: 5m
      labels:
        severity: warning
      annotations:
        summary: "CPU使用率过高"
        description: "节点 {{ \$labels.instance }} CPU使用率超过85%，当前值 {{ \$value }}%"
        
    - alert: NodeHighMemory
      expr: (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100 > 85
      for: 5m
      labels:
        severity: warning
      annotations:
        summary: "内存使用率过高"
        description: "节点 {{ \$labels.instance }} 内存使用率超过85%，当前值 {{ \$value }}%"
        
    - alert: NodeDiskSpaceLow
      expr: (1 - node_filesystem_avail_bytes{fstype!~"tmpfs|overlay"} / node_filesystem_size_bytes) * 100 > 85
      for: 5m
      labels:
        severity: critical
      annotations:
        summary: "磁盘空间不足"
        description: "节点 {{ \$labels.instance }} 磁盘使用率超过85%"
        
    - alert: NodeDown
      expr: up{job="node-exporter"} == 0
      for: 1m
      labels:
        severity: critical
      annotations:
        summary: "节点宕机"
        description: "节点 {{ \$labels.instance }} 已离线"
        
  - name: pod-alerts
    rules:
    - alert: PodCrashLooping
      expr: rate(kube_pod_container_status_restarts_total[15m]) * 60 * 15 > 0
      for: 5m
      labels:
        severity: warning
      annotations:
        summary: "Pod频繁重启"
        description: "Pod {{ \$labels.namespace }}/{{ \$labels.pod }} 在15分钟内重启超过5次"
        
    - alert: PodNotReady
      expr: kube_pod_status_ready{condition="true"} == 0
      for: 10m
      labels:
        severity: warning
      annotations:
        summary: "Pod未就绪"
        description: "Pod {{ \$labels.namespace }}/{{ \$labels.pod }} 长时间未就绪"
        
  - name: deployment-alerts
    rules:
    - alert: DeploymentReplicasMismatch
      expr: kube_deployment_spec_replicas != kube_deployment_status_ready_replicas
      for: 10m
      labels:
        severity: warning
      annotations:
        summary: "Deployment副本数不匹配"
        description: "Deployment {{ \$labels.namespace }}/{{ \$labels.deployment }} 期望副本数与就绪副本数不一致"
EOF

# 验证
echo "[4/4] 验证安装..."
kubectl -n monitoring get pods
kubectl -n monitoring get svc

echo ""
echo "✅ 监控系统安装完成!"
echo ""
echo "📌 访问地址:"
echo "   Grafana:      http://<EXTERNAL-IP>"
echo "   Prometheus:   http://<EXTERNAL-IP>:9090"
echo "   AlertManager: http://<EXTERNAL-IP>:9093"
echo ""
echo "📌 Grafana默认账号: admin / Admin@2024"
echo "📌 推荐Dashboard ID: 315, 6417, 13770"
```

### 第九步: 安装日志系统

```bash
bash 09-install-logging.sh
```

**09-install-logging.sh**:
```bash
#!/bin/bash
# ============================================
# Loki + Promtail 日志收集系统安装
# ============================================

set -euo pipefail

echo "=========================================="
echo "  安装 Loki + Promtail 日志系统"
echo "=========================================="

# 添加Helm仓库
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

# 安装Loki
echo "[1/3] 安装Loki..."
helm install loki grafana/loki \
    --namespace monitoring \
    --set persistence.enabled=true \
    --set persistence.storageClassName=nfs-client \
    --set persistence.size=50Gi \
    --set resources.requests.cpu=500m \
    --set resources.requests.memory=1Gi \
    --set auth.enabled=false

# 安装Promtail
echo "[2/3] 安装Promtail..."
helm install promtail grafana/promtail \
    --namespace monitoring \
    --set config.lokiAddress=http://loki:3100/loki/api/v1/push

# 等待就绪
echo "[3/3] 等待组件就绪..."
kubectl -n monitoring wait --for=condition=Ready pod -l app.kubernetes.io/name=loki --timeout=300s

# 在Grafana中添加Loki数据源
echo ""
echo "📌 在Grafana中配置Loki数据源:"
echo "   1. 打开Grafana -> Configuration -> Data Sources"
echo "   2. 添加Loki数据源"
echo "   3. URL: http://loki:3100"
echo "   4. 保存并测试"
echo ""
echo "📌 查询示例:"
echo "   {namespace=\"default\"} | logfmt"
echo "   {pod=~\"app.*\"} |= \"error\""
echo "   {container=\"nginx\"} | json | level=\"error\""

echo ""
echo "✅ 日志系统安装完成!"
```

### 第十步: 部署示例应用

```bash
bash 10-deploy-application.sh
```

**10-deploy-application.sh**:
```bash
#!/bin/bash
# ============================================
# 示例应用完整部署
# ============================================

set -euo pipefail

echo "=========================================="
echo "  部署示例应用"
echo "=========================================="

# 应用命名空间
NAMESPACE="production"

# 创建命名空间和资源配额
echo "[1/6] 创建命名空间..."
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: ${NAMESPACE}
  labels:
    name: production
---
apiVersion: v1
kind: ResourceQuota
metadata:
  name: compute-quota
  namespace: ${NAMESPACE}
spec:
  hard:
    requests.cpu: "10"
    requests.memory: 20Gi
    limits.cpu: "20"
    limits.memory: 40Gi
    pods: "50"
    services: "20"
    persistentvolumeclaims: "10"
EOF

# RBAC配置
echo "[2/6] 配置RBAC..."
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: app-sa
  namespace: ${NAMESPACE}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: app-role
  namespace: ${NAMESPACE}
rules:
- apiGroups: [""]
  resources: ["configmaps", "secrets"]
  verbs: ["get", "list", "watch"]
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: app-rolebinding
  namespace: ${NAMESPACE}
subjects:
- kind: ServiceAccount
  name: app-sa
  namespace: ${NAMESPACE}
roleRef:
  kind: Role
  name: app-role
  apiGroup: rbac.authorization.k8s.io
EOF

# ConfigMap和Secret
echo "[3/6] 创建ConfigMap和Secret..."
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-config
  namespace: ${NAMESPACE}
data:
  APP_NAME: "Enterprise App"
  LOG_LEVEL: "info"
  CACHE_TTL: "3600"
  MAX_CONNECTIONS: "100"
  config.json: |
    {
      "database": {
        "host": "mysql-service",
        "port": 3306,
        "name": "enterprise_app"
      },
      "redis": {
        "host": "redis-service",
        "port": 6379
      }
    }
---
apiVersion: v1
kind: Secret
metadata:
  name: app-secrets
  namespace: ${NAMESPACE}
type: Opaque
data:
  DB_PASSWORD: WWVvdXJTdHJvbmdEQjEyMw==    # base64编码
  REDIS_PASSWORD: WWVvdXJTdHJvbmdSZWRpczEyMw==
  API_KEY: c2VjcmV0LWFwaS1rZXktMjAyNA==
EOF

# 网络策略
echo "[4/6] 配置网络策略..."
cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
  namespace: ${NAMESPACE}
spec:
  podSelector: {}
  policyTypes:
  - Ingress
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-frontend-to-backend
  namespace: ${NAMESPACE}
spec:
  podSelector:
    matchLabels:
      app: backend
  policyTypes:
  - Ingress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          app: frontend
    ports:
    - protocol: TCP
      port: 8000
EOF

# 应用部署
echo "[5/6] 部署应用..."
kubectl -n ${NAMESPACE} apply -f - <<'MANIFESTS'
---
# Deployment
apiVersion: apps/v1
kind: Deployment
metadata:
  name: enterprise-app
  labels:
    app: backend
spec:
  replicas: 3
  selector:
    matchLabels:
      app: backend
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  template:
    metadata:
      labels:
        app: backend
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "8000"
        prometheus.io/path: "/metrics"
    spec:
      serviceAccountName: app-sa
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        fsGroup: 1000
      containers:
      - name: app
        image: nginx:1.25-alpine
        ports:
        - containerPort: 8000
          name: http
        envFrom:
        - configMapRef:
            name: app-config
        - secretRef:
            name: app-secrets
        resources:
          requests:
            cpu: 250m
            memory: 256Mi
          limits:
            cpu: 1000m
            memory: 1Gi
        livenessProbe:
          httpGet:
            path: /health
            port: 8000
          initialDelaySeconds: 15
          periodSeconds: 20
          timeoutSeconds: 5
          failureThreshold: 3
        readinessProbe:
          httpGet:
            path: /ready
            port: 8000
          initialDelaySeconds: 5
          periodSeconds: 10
          timeoutSeconds: 3
          failureThreshold: 3
        startupProbe:
          httpGet:
            path: /health
            port: 8000
          initialDelaySeconds: 10
          periodSeconds: 5
          failureThreshold: 30
      topologySpreadConstraints:
      - maxSkew: 1
        topologyKey: kubernetes.io/hostname
        whenUnsatisfiable: DoNotSchedule
        labelSelector:
          matchLabels:
            app: backend
---
# Service
apiVersion: v1
kind: Service
metadata:
  name: app-service
  labels:
    app: backend
spec:
  type: ClusterIP
  ports:
  - port: 80
    targetPort: 8000
    protocol: TCP
    name: http
  selector:
    app: backend
---
# Ingress
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: app-ingress
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/proxy-body-size: "50m"
    nginx.ingress.kubernetes.io/rate-limit: "100"
    nginx.ingress.kubernetes.io/rate-limit-window: "1m"
spec:
  ingressClassName: nginx
  tls:
  - hosts:
    - app.your-domain.com
    secretName: app-tls
  rules:
  - host: app.your-domain.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: app-service
            port:
              number: 80
---
# HPA
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: app-hpa
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: enterprise-app
  minReplicas: 3
  maxReplicas: 20
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 70
  - type: Resource
    resource:
      name: memory
      target:
        type: Utilization
        averageUtilization: 80
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 60
      policies:
      - type: Pods
        value: 4
        periodSeconds: 60
    scaleDown:
      stabilizationWindowSeconds: 300
      policies:
      - type: Percent
        value: 10
        periodSeconds: 120
---
# PDB
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: app-pdb
spec:
  minAvailable: 2
  selector:
    matchLabels:
      app: backend
MANIFESTS

# 验证
echo "[6/6] 验证部署..."
kubectl -n ${NAMESPACE} get all
kubectl -n ${NAMESPACE} get ingress

echo ""
echo "✅ 应用部署完成!"
echo ""
echo "📌 查看状态:"
echo "   kubectl -n production get pods -o wide"
echo "   kubectl -n production logs -f deployment/enterprise-app"
echo "   kubectl -n production describe svc app-service"
```

---

## 🔧 运维手册

### 常用kubectl命令

```bash
# 集群信息
kubectl cluster-info
kubectl get nodes -o wide
kubectl get componentstatuses

# 查看资源
kubectl get pods -A                          # 所有命名空间的Pod
kubectl get pods -n production -o wide       # 指定命名空间
kubectl describe pod <pod-name> -n <ns>      # 详细信息
kubectl logs -f <pod-name> -n <ns>           # 实时日志
kubectl logs --previous <pod-name> -n <ns>   # 上一次崩溃的日志

# 调试
kubectl exec -it <pod-name> -n <ns> -- /bin/sh  # 进入容器
kubectl port-forward svc/app-service 8080:80 -n production  # 端口转发
kubectl top pods -n production               # 资源使用

# 扩缩容
kubectl scale deployment enterprise-app --replicas=5 -n production
kubectl rollout restart deployment enterprise-app -n production

# 故障排查
kubectl get events -n production --sort-by='.lastTimestamp'
kubectl describe nodes
kubectl get pods --field-selector=status.phase!=Running -A
```

### 故障排查清单

| 问题 | 排查命令 |
|------|---------|
| Pod Pending | `kubectl describe pod <name>` 看Events |
| Pod CrashLoopBackOff | `kubectl logs <name> --previous` |
| Service无法访问 | `kubectl get endpoints <svc-name>` |
| DNS解析失败 | `kubectl run dns-test --image=busybox --rm -it -- nslookup kubernetes.default` |
| 节点NotReady | `kubectl describe node <name>` 看Conditions |
| PVC绑定失败 | `kubectl get pvc -A` + `kubectl get pv` |

---

**作者**: 企业级运维项目集
**版本**: 1.0.0
**更新时间**: 2026-05-02
