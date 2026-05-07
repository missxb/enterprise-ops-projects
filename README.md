# 企业级运维项目集

> 基于官方文档和技术博客整理的运维参考方案，覆盖容器、CI/CD、监控、日志、数据库、缓存、网关、安全等核心领域。
>
> 每个项目包含：架构设计、部署配置、故障案例、调优参数、灾备方案、成本估算、运维SOP
>
> 声明：本文档为技术方案参考，非可直接执行的生产脚本。实际部署请根据环境调整。

---

## 📁 项目列表（2026年5月更新）

| # | 项目 | 技术栈 | 规模 |
|---|------|--------|------|
| 01 | [容器云平台](01-企业级容器云平台-Docker-K8s-Harbor-Helm.md) | containerd 2.3.0 + K8s 1.35.4 + Harbor 2.15.1 + Helm 3 + Calico 3.32.0 | 78KB |
| 02 | [CI/CD全链路](02-企业级CI-CD全链路-Jenkins-SonarQube-ArgoCD-K8s.md) | Jenkins + SonarQube + ArgoCD + Trivy | 48KB |
| 03 | [Prometheus监控](03-企业级Prometheus-Grafana监控告警体系.md) | Prometheus 3.11.3 + Thanos 0.41.0 + Grafana | 53KB |
| 04 | [ELK日志平台](04-企业级ELK-EFK日志分析平台.md) | ES 8.x + Filebeat + Kafka + Kibana | 56KB |
| 05 | [MySQL高可用](05-企业级MySQL高可用集群-MGR-ProxySQL-备份.md) | MySQL 8.4 LTS MGR + ProxySQL + Xtrabackup | 50KB |
| 06 | [Redis集群](06-企业级Redis集群方案-Cluster-Sentinel-持久化.md) | Redis 8.6 Cluster + Sentinel | 30KB |
| 07 | [Nginx高可用](07-企业级Nginx-Keepalived高可用.md) | Nginx + Keepalived + SSL + WAF | 59KB |
| 08 | [Ansible+Terraform](08-企业级Ansible-Terraform自动化运维.md) | Ansible + Terraform(阿里云) | 47KB |
| 09 | [K8s微服务网关](09-企业级K8s微服务网关-服务治理.md) | Kong 3.9.1 + Istio 1.29.2 + Jaeger | 55KB |
| 10 | [安全加固与等保](10-企业级安全加固与等保合规.md) | 主机加固 + K8s安全 + 等保3.0(2025年发布) | 71KB |

**总计: 10个项目, ~570KB**

---

## 📌 版本兼容性矩阵（2026年5月）

> 本项目所有组件使用2026年5月最新版本，确保安全补丁和合规性。

| 组件 | 版本 | 发布日期 | 支持周期 | 说明 |
|------|------|----------|----------|------|
| Kubernetes | 1.35.4 | 2026-04 | LTS | 当前最新稳定版 |
| containerd | 2.3.0 | 2026-04 | - | 最新稳定版 |
| Harbor | 2.15.1 | 2026-03 | LTS | 当前最新版 |
| MySQL | 8.4 LTS | 2026-04 | 8年 | 长期支持版本 |
| Redis | 8.6.3 | 2026-05 | - | 最新稳定版 |
| Prometheus | 3.11.3 | 2026-04 | - | 最新稳定版 |
| Thanos | 0.41.0 | 2026-04 | - | 最新稳定版 |
| Kong | 3.9.1 | 2026-04 | LTS | 最新稳定版 |
| Calico | 3.32.0 | 2026-04 | - | 最新稳定版 |
| Istio | 1.29.2 | 2026-04 | LTS | 最新稳定版 |

> **⚠️ EOL警告**：
> - MySQL 8.0已于2026-04-30 EOL，本项目使用8.4 LTS
> - Kubernetes 1.31已于2025-10 EOL，本项目使用1.35.4
> - Harbor 2.12已于2026-03 EOL，本项目使用2.15.1
> - 等保三级要求使用受支持的软件版本

---

## 📂 部署脚本

每个项目配套生产级部署脚本，所有脚本包含: `set -euo pipefail` + `umask 077` + 变量检查 + 错误处理 + 依赖声明

| # | 脚本 | 用途 | 依赖 |
|---|------|------|------|
| 01 | [node-init.sh](scripts/01-k8s/node-init.sh) | K8s节点初始化 | kubeadm, containerd |
| 01 | [harbor-deploy.sh](scripts/01-k8s/harbor-deploy.sh) | Harbor单实例 | docker-ce |
| 01 | [harbor-ha.sh](scripts/01-k8s/harbor-ha.sh) | Harbor生产HA | 外部PG/Redis |
| 01 | [etcd-backup.sh](scripts/01-k8s/etcd-backup.sh) | etcd备份 | kubectl |
| 01 | [etcd-restore.sh](scripts/01-k8s/etcd-restore.sh) | etcd恢复 | etcdctl |
| 02 | [cicd-deploy.sh](scripts/02-cicd/cicd-deploy.sh) | CI/CD全链路 | kubectl |
| 03 | [monitor-deploy.sh](scripts/03-monitor/monitor-deploy.sh) | Prometheus+Grafana | kubectl, helm |
| 03 | [monitor-check.sh](scripts/03-monitor/monitor-check.sh) | 监控检查 | curl, jq |
| 04 | [elk-deploy.sh](scripts/04-elk/elk-deploy.sh) | ELK日志平台 | kubectl, helm |
| 04 | [elk-check.sh](scripts/04-elk/elk-check.sh) | ELK健康检查 | curl, jq |
| 05 | [mysql-cluster-deploy.sh](scripts/05-mysql/mysql-cluster-deploy.sh) | MySQL MGR集群 | mysql 8.4 LTS |
| 05 | [mysql-backup.sh](scripts/05-mysql/mysql-backup.sh) | MySQL全量备份 | xtrabackup |
| 05 | [pitr-restore.sh](scripts/05-mysql/pitr-restore.sh) | MySQL PITR恢复 | xtrabackup, mysqlbinlog |
| 06 | [redis-cluster-deploy.sh](scripts/06-redis/redis-cluster-deploy.sh) | Redis Cluster | redis 8.6+ |
| 06 | [redis-backup.sh](scripts/06-redis/redis-backup.sh) | Redis集群备份 | redis-cli |
| 07 | [nginx-ha-deploy.sh](scripts/07-nginx/nginx-ha-deploy.sh) | Nginx+Keepalived | nginx, keepalived |
| 07 | [nginx-check.sh](scripts/07-nginx/nginx-check.sh) | Nginx配置检查 | nginx, curl |
| 08 | [ansible-deploy.sh](scripts/08-ansible/ansible-deploy.sh) | Ansible批量部署 | ansible |
| 09 | [gateway-deploy.sh](scripts/09-gateway/gateway-deploy.sh) | K8s微服务网关 | kubectl, helm, istioctl |
| 10 | [security-harden.sh](scripts/10-security/security-harden.sh) | 服务器安全加固 | ssh |
| 10 | [security-check.sh](scripts/10-security/security-check.sh) | 安全快速检查 | - |
| 10 | [compliance-check.sh](scripts/10-security/compliance-check.sh) | 等保合规检查 | grep, systemctl |

## 📚 文档

| 文档 | 内容 |
|------|------|
| [变更管理](docs/change-management.md) | 灰度发布 + DDL审核 + 金丝雀发布脚本 |
| [灾备演练SOP](docs/disaster-recovery-sop.md) | 演练checklist + 跨机房etcd + 混沌工程 |
| [容量规划](docs/capacity-planning.md) | 资源基线 + 扩容阈值 + 自动巡检脚本 |
| [GitOps工作流](docs/gitops-workflow.md) | ArgoCD Application + ApplicationSet |
| [性能基准](docs/performance-benchmarks.md) | MySQL/Redis/K8s性能数据 |
| [灾备演练模板](docs/dr-drill-record-template.md) | 演练记录填写模板 |

---

## 📌 组件联动关系

| 项目 | 上游依赖 | 下游集成 |
|------|----------|----------|
| 01-K8s | 网络/存储 | 02-09全部项目 |
| 02-CI/CD | 01-K8s, 05-MySQL | Harbor镜像, K8s部署 |
| 03-监控 | 01-K8s | 告警→PagerDuty→人工确认→Ansible |
| 04-ELK | 01-K8s | 日志分析(与03并行) |
| 05-MySQL | 01-K8s | 04-ELK收集慢查询日志 |
| 06-Redis | 01-K8s | 04-ELK收集Redis日志 |
| 07-Nginx | 01-K8s | 访问日志→04-ELK |
| 08-Ansible | 01-K8s | 人工确认后执行修复 |
| 09-网关 | 01-K8s | 流量→05-MySQL/06-Redis |
| 10-安全 | 01-K8s | CI/CD构建时触发Trivy扫描 |

> **核心链路**: 代码→CI/CD构建→Trivy扫描→Harbor镜像→ArgoCD部署→K8s(渐进式发布)→监控告警→安全审计
>
> **⚠️ 安全规则**: 监控告警→自动修复必须经过人工审批，禁止直接自动化执行

## 📌 项目定位

本仓库是**单一、独立**的运维参考文档集。与学习笔记不同，本文档按生产环境标准组织：
- 所有配置文件带完整注释
- 每个项目有8个以上故障排查案例
- 包含成本估算和运维SOP
- 密码使用环境变量占位符，不硬编码

## ⚠️ 已知局限

1. **非可执行代码**: 本文档为配置参考，脚本需要根据实际环境修改后才能运行
2. **单一作者视角**: 故障案例来自公开技术博客和社区分享，非实际生产经历
3. **版本局限**: 组件版本基于2024-2025年主流版本，新版本可能有API变化

---

## 版本兼容性矩阵

> **版本说明**: 以下版本为2026年5月最新版本，确保安全补丁和合规性。
> - MySQL 8.0已于2026-04-30 EOL，本项目使用8.4 LTS
> - Kubernetes 1.31已于2025-10 EOL，本项目使用1.35.4
> - Harbor 2.12已于2026-03 EOL，本项目使用2.15.1
> - 等保三级要求使用受支持的软件版本

| 组件 | 版本 | 依赖 | 兼容说明 |
|------|------|------|----------|
| K8s | 1.35.4 | containerd 2.3.0+ | LTS版本 |
| Calico | 3.32.0 | K8s 1.35 | 支持eBPF模式(内核5.10+) |
| MetalLB | 0.15.3 | K8s 1.24+ | L2模式需ARP，公有云不支持 |
| Istio | 1.29.2 | K8s 1.35 | 支持Ambient Mesh(已GA) |
| Harbor | 2.15.1 | K8s 1.35 | Helm安装，需外部PG/Redis/S3 |
| Prometheus | 3.11.3 | K8s 1.25+ | Thanos 0.41.0兼容 |
| Thanos | 0.41.0 | Prometheus 3.x | Sidecar需Prometheus |
| MySQL | 8.4 LTS | ProxySQL 2.6+ | MGR需GTID，支持8年 |
| Redis | 8.6.3 | - | Cluster需6节点 |
| Kong | 3.9.1 | - | 支持K8s Gateway API |

---

## 场景适配指南

| 企业规模 | 推荐方案 | 节点数 | 月成本估算 |
|---------|---------|--------|-----------|
| 小型(50人以下) | K8s 3节点 + Redis Sentinel + 单ES | 8-10台 | 15,000-25,000元(含计算/存储/带宽/SLB/人力) |
| 中型(50-500人) | K8s 5节点 + Redis Cluster + ES 3节点 | 15-20台 | 30,000-50,000元(含存储/带宽/License/人力) |
| 大型(500人以上) | K8s HA + Redis Cluster 6节点 + ES热温冷 | 30-50台 | 100,000-200,000元(含跨机房/专线/License/安全设备) |

| 部署环境 | 注意事项 |
|---------|----------|
| 公有云(阿里云) | 使用云厂商LB/RDS/Redis替代自建，成本更高但运维更简单 |
| 私有云/IDC | 需自建LB(HAProxy+Keepalived)、监控、日志全套 |
| 混合云 | K8s联邦+跨云网络打通，复杂度最高 |

| 行业合规 | 额外要求 |
|---------|----------|
| 互联网 | 基础安全加固即可 |
| 金融/政务(等保三级) | 审计日志留存180天、双因素认证、漏洞扫描、渗透测试 |
| 医疗 | 数据脱敏、访问审计、等保三级 |

---

## 📜 License

[MIT](LICENSE)
