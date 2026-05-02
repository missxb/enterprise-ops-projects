# 企业级运维项目实战合集

> 基于25个语雀知识库(2,699篇文档, 584万字)深度学习后的实战产出
> 涵盖容器化、CI/CD、监控、日志、数据库、缓存、网关、自动化、安全全栈

---

## 📁 项目清单

| # | 项目 | 技术栈 | 规模 |
|---|------|--------|------|
| 01 | 企业级容器云平台 | Docker + K8s + Harbor + Helm + Calico + MetalLB | 43KB |
| 02 | 企业级CI/CD全链路 | Jenkins + GitLab CI + SonarQube + ArgoCD + Trivy | 36KB |
| 03 | 企业级监控告警体系 | Prometheus + Grafana + Thanos + AlertManager + 50+告警规则 | 34KB |
| 04 | 企业级ELK日志平台 | Elasticsearch + Filebeat + Kibana + ILM生命周期 | 16KB |
| 05 | 企业级MySQL高可用 | MGR集群 + ProxySQL读写分离 + xtrabackup备份 + PITR | 12KB |
| 06 | 企业级Redis集群 | Cluster 6节点 + Sentinel哨兵 + 分布式锁 | 10KB |
| 07 | 企业级Nginx高可用 | Nginx + Keepalived VIP + SSL + 限流 + WAF | 8KB |
| 08 | 企业级自动化运维 | Ansible配置管理 + Terraform IaC(阿里云) | 12KB |
| 09 | 企业级微服务网关 | Kong Gateway + Istio服务网格 + Jaeger链路追踪 | 10KB |
| 10 | 企业级安全加固 | 主机加固 + K8s安全 + 等保合规 + 堡垒机 | 10KB |

**总计: 10个项目, 191KB, 覆盖企业运维全栈**

---

## 🏗️ 架构全景

```
                        ┌─────────────────────────────────┐
                        │        安全管理中心              │
                        │   堡垒机 + SIEM + 等保合规      │
                        └──────────────┬──────────────────┘
                                       │
         ┌─────────────────────────────┼─────────────────────────────┐
         │                             │                             │
┌────────▼────────┐  ┌─────────────────▼─────────────────┐  ┌───────▼────────┐
│   应用交付层     │  │          基础设施层                  │  │    数据层       │
│                 │  │                                     │  │                │
│  CI/CD Pipeline │  │  K8s Cluster (3M + 5W)             │  │  MySQL MGR     │
│  Jenkins+ArgoCD │  │  Docker + Harbor + Helm            │  │  Redis Cluster │
│  SonarQube      │  │  Nginx+Keepalived                  │  │  Elasticsearch │
│  Trivy扫描      │  │  Ansible + Terraform                │  │                │
└─────────────────┘  └───────────────────────────────────┘  └────────────────┘
         │                             │                             │
         └─────────────────────────────┼─────────────────────────────┘
                                       │
                        ┌──────────────▼──────────────┐
                        │       可观测性层              │
                        │  Prometheus + Grafana        │
                        │  AlertManager + Thanos       │
                        │  ELK/EFK 日志平台            │
                        │  Jaeger 链路追踪             │
                        └─────────────────────────────┘
```

---

## 🎯 技术覆盖

- **容器化**: Docker, Containerd, Harbor, Helm, Kustomize
- **编排调度**: Kubernetes 1.28, kubeadm, Calico, MetalLB
- **CI/CD**: Jenkins, GitLab CI, ArgoCD, SonarQube, Trivy
- **监控告警**: Prometheus, Grafana, Thanos, AlertManager, 50+告警规则
- **日志分析**: Elasticsearch, Filebeat, Kibana, ILM生命周期
- **数据库**: MySQL MGR, ProxySQL, xtrabackup, PITR
- **缓存**: Redis Cluster, Sentinel, 分布式锁
- **网关**: Nginx, Kong, HAProxy, Keepalived
- **服务网格**: Istio, 虚拟服务, 金丝雀发布
- **链路追踪**: Jaeger, OpenTelemetry
- **自动化**: Ansible, Terraform (阿里云)
- **安全加固**: 主机加固, K8s安全, 等保合规, 堡垒机

---

## 📊 知识来源

本项目基于以下25个语雀知识库的全量学习(2,699篇文档, 584万字):

| 知识库 | 文档数 | 核心内容 |
|--------|--------|----------|
| 技术沙龙 | 124 | 云运维实战 |
| 项目知识库 | 21 | 企业项目实战 |
| Linux | 241 | Linux全面知识 |
| 云计算运维 | 119 | 云运维公开知识 |
| 运维相关 | 304 | 最全面的运维库 |
| 学习知识库 | 1,222 | 超大知识库 |
| 运维知识库(多个) | 188 | 运维实战 |
| Docker学习 | 41 | Docker深度 |
| 云原生K8S | 34 | K8S+DevOps |
| 分布式 | 22 | 分布式系统 |
| Linux笔记 | 100 | Jenkins/Docker/K8s |
| 知识点 | 85 | 基础+进阶 |
| K8S(多个) | 127 | K8S+监控+CI/CD |
| 云原生 | 61 | Helm+集群 |
| 其他 | 24 | 运维devops |

---

## 🚀 快速开始

每个项目文件包含完整的:
- 架构设计图
- 服务器规划表
- 完整配置文件
- 部署脚本
- 运维命令速查
- 故障处理方案

建议按以下顺序学习:
1. 01 容器云平台 → 2. 08 自动化运维 → 3. 02 CI/CD → 4. 03 监控 → 5. 04 日志
6. 05 MySQL → 7. 06 Redis → 8. 07 Nginx → 9. 09 微服务网关 → 10. 10 安全加固
