# 🏢 企业级运维项目集合

> 从零到一的完整企业级运维实战项目，覆盖DevOps全链路

---

## 📚 项目列表

| # | 项目名称 | 技术栈 | 难度 | 说明 |
|---|---------|--------|------|------|
| 01 | Docker Compose全栈Web应用 | Nginx + FastAPI + MySQL + Redis | ⭐⭐ | 生产级Web应用部署方案 |
| 02 | Kubernetes生产集群搭建 | kubeadm + Calico + MetalLB | ⭐⭐⭐⭐ | 多节点K8s集群完整搭建 |
| 03 | Prometheus+Grafana监控告警 | Prometheus + Grafana + AlertManager | ⭐⭐⭐ | 全链路监控告警系统 |
| 04 | Jenkins CI/CD完整流水线 | Jenkins + Docker + K8s + ArgoCD | ⭐⭐⭐⭐ | 企业级CI/CD全流程 |
| 05 | Ansible自动化运维平台 | Ansible + Playbooks + Roles | ⭐⭐⭐ | 批量服务器自动化管理 |
| 06 | Terraform云基础设施IaC | AWS + EKS + RDS + VPC | ⭐⭐⭐⭐ | 基础设施即代码 |
| 07 | ELK Stack日志分析系统 | Elasticsearch + Logstash + Kibana | ⭐⭐⭐ | 企业级日志收集分析 |

---

## 🗺️ 学习路线

```
阶段1: 基础部署 (2周)
├── 01-Docker Compose全栈部署
└── 掌握: Docker, Docker Compose, 容器化基础

阶段2: 容器编排 (3周)
├── 02-Kubernetes集群搭建
└── 掌握: K8s核心概念, Pod, Service, Ingress, HPA

阶段3: 监控告警 (2周)
├── 03-Prometheus+Grafana监控
└── 掌握: 监控指标, 告警规则, PromQL

阶段4: CI/CD (3周)
├── 04-Jenkins CI/CD流水线
└── 掌握: 自动化构建, 镜像管理, 滚动更新

阶段5: 自动化运维 (2周)
├── 05-Ansible自动化平台
└── 掌握: 配置管理, Playbook, Role

阶段6: 云基础设施 (3周)
├── 06-Terraform AWS架构
└── 掌握: IaC, AWS服务, 状态管理

阶段7: 日志分析 (2周)
├── 07-ELK Stack日志系统
└── 掌握: 日志采集, 索引管理, 可视化
```

---

## 🛠️ 环境要求

### 本地环境
- **操作系统**: Ubuntu 22.04 / CentOS 7+ / macOS 12+
- **Docker**: 24.0+
- **Docker Compose**: 2.20+
- **kubectl**: 1.28+
- **Ansible**: 2.15+
- **Terraform**: 1.5+

### 云环境 (项目06)
- **AWS账号**: 拥有足够权限
- **域名**: 已备案域名
- **SSL证书**: ACM证书

---

## 📖 使用说明

### 快速开始

```bash
# 克隆项目
git clone https://github.com/missxb/enterprise-ops-projects.git
cd enterprise-ops-projects

# 查看项目列表
ls -la

# 选择项目学习
cd 01-docker-compose-web-stack
# 按照README.md操作
```

### 环境准备

```bash
# 安装Docker
curl -fsSL https://get.docker.com | sh

# 安装Docker Compose
sudo apt install docker-compose-plugin

# 安装kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

# 安装Ansible
pip install ansible

# 安装Terraform
wget https://releases.hashicorp.com/terraform/1.6.6/terraform_1.6.6_linux_amd64.zip
unzip terraform_1.6.6_linux_amd64.zip
sudo mv terraform /usr/local/bin/
```

---

## 🎯 核心技能

通过本项目集合，你将掌握:

### Linux基础
- [x] 系统管理与性能调优
- [x] 服务管理 (systemd)
- [x] Shell脚本编程
- [x] 网络配置与安全

### 容器化技术
- [x] Docker镜像构建与优化
- [x] Docker Compose编排
- [x] 容器网络与存储
- [x] 容器安全最佳实践

### Kubernetes
- [x] 集群搭建与管理
- [x] 工作负载管理
- [x] 服务发现与负载均衡
- [x] 自动扩缩容
- [x] 持久化存储
- [x] RBAC安全

### 监控告警
- [x] Prometheus指标采集
- [x] Grafana可视化
- [x] AlertManager告警
- [x] PromQL查询

### CI/CD
- [x] Jenkins Pipeline
- [x] 镜像构建与推送
- [x] 自动化测试
- [x] GitOps部署
- [x] 滚动更新与回滚

### 自动化运维
- [x] Ansible Playbook
- [x] Role开发
- [x] 配置管理
- [x] 批量操作

### 云原生
- [x] AWS基础服务
- [x] VPC网络架构
- [x] EKS集群管理
- [x] RDS数据库
- [x] ElastiCache

### 日志分析
- [x] ELK Stack部署
- [x] 日志采集配置
- [x] 索引生命周期
- [x] 可视化仪表盘

---

## 📊 项目统计

- **项目数量**: 7个完整企业级项目
- **配置文件**: 50+个生产级配置
- **代码行数**: 5000+行
- **覆盖技术**: 30+种工具和框架
- **文档**: 每个项目都有完整README

---

## 🤝 贡献指南

欢迎提交Issues和Pull Requests!

1. Fork本仓库
2. 创建特性分支 (`git checkout -b feature/AmazingFeature`)
3. 提交更改 (`git commit -m 'Add some AmazingFeature'`)
4. 推送到分支 (`git push origin feature/AmazingFeature`)
5. 创建Pull Request

---

## 📄 许可证

本项目采用 MIT 许可证 - 详见 [LICENSE](LICENSE) 文件

---

## 📞 联系方式

- **GitHub**: [missxb](https://github.com/missxb)
- **Email**: 13825462467@163.com

---

**⭐ 如果这个项目对你有帮助，请给个Star支持一下！**
