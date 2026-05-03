# 企业级运维项目集

> 基于官方文档和技术博客整理的运维参考方案，覆盖容器、CI/CD、监控、日志、数据库、缓存、网关、安全等核心领域。
>
> 每个项目包含：架构设计、部署配置、故障案例、调优参数、灾备方案、成本估算、运维SOP
>
> 声明：本文档为技术方案参考，非可直接执行的生产脚本。实际部署请根据环境调整。

---

## 📁 项目列表

| # | 项目 | 技术栈 | 规模 |
|---|------|--------|------|
| 01 | [容器云平台](01-企业级容器云平台-Docker-K8s-Harbor-Helm.md) | Docker + K8s 1.28 + Harbor 2.9 + Helm | 56KB |
| 02 | [CI/CD全链路](02-企业级CI-CD全链路-Jenkins-SonarQube-ArgoCD-K8s.md) | Jenkins + SonarQube + ArgoCD | 48KB |
| 03 | [Prometheus监控](03-企业级Prometheus-Grafana监控告警体系.md) | Prometheus 2.50 + Thanos 0.34 + Grafana | 53KB |
| 04 | [ELK日志平台](04-企业级ELK-EFK日志分析平台.md) | ES 8.x + Filebeat + Kafka + Kibana | 56KB |
| 05 | [MySQL高可用](05-企业级MySQL高可用集群-MGR-ProxySQL-备份.md) | MySQL 8.0 MGR + ProxySQL + Xtrabackup | 50KB |
| 06 | [Redis集群](06-企业级Redis集群方案-Cluster-Sentinel-持久化.md) | Redis 7.0 Cluster + Sentinel | 30KB |
| 07 | [Nginx高可用](07-企业级Nginx-Keepalived高可用.md) | Nginx + Keepalived + SSL + WAF | 59KB |
| 08 | [Ansible+Terraform](08-企业级Ansible-Terraform自动化运维.md) | Ansible + Terraform(阿里云) | 47KB |
| 09 | [K8s微服务网关](09-企业级K8s微服务网关-服务治理.md) | Kong 3.5 + Istio 1.20 + Jaeger | 55KB |
| 10 | [安全加固与等保](10-企业级安全加固与等保合规.md) | 主机加固 + K8s安全 + 等保三级 | 53KB |

**总计: 10个项目, ~500KB**

---

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

| 组件 | 版本 | 依赖 | 兼容说明 |
|------|------|------|----------|
| K8s | 1.28 | containerd 1.7+ | 需要CRI v1 |
| Calico | 3.26 | K8s 1.28 | BGP模式需内核4.19+ |
| MetalLB | 0.13 | K8s 1.24+ | L2模式需ARP |
| Istio | 1.20 | K8s 1.28 | Sidecar兼容性 |
| Harbor | 2.9 | K8s 1.28 | Helm安装 |
| Prometheus | 2.50 | K8s 1.25+ | Thanos 0.34兼容 |
| Thanos | 0.34 | Prometheus 2.30+ | Sidecar需Prometheus |
| MySQL | 8.0 | ProxySQL 2.6+ | MGR需GTID |
| Redis | 7.0 | - | Cluster需6节点 |
| Kong | 3.5 | - | DB-less模式有限制 |

---

## 📜 License

[MIT](LICENSE)
