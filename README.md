# 运维技术学习笔记与实践整理

> 个人学习DevOps过程中的笔记整理与实践记录
> 部分内容来源于公开技术文档、官方文档和社区分享
>
> 适用对象：有一定Linux基础，想系统学习运维技术的工程师
> 说明：文档仅供参考学习，实际使用请根据自身环境调整

---

## 📁 项目列表

| # | 项目 | 技术栈 | 规模 |
|---|------|--------|------|
| 01 | [容器云平台](01-企业级容器云平台-Docker-K8s-Harbor-Helm.md) | Docker + K8s + Harbor + Helm + Calico + MetalLB | 56KB |
| 02 | [CI/CD全链路](02-企业级CI-CD全链路-Jenkins-SonarQube-ArgoCD-K8s.md) | Jenkins + SonarQube + ArgoCD + K8s | 48KB |
| 03 | [Prometheus监控](03-企业级Prometheus-Grafana监控告警体系.md) | Prometheus + Grafana + Thanos + AlertManager | 53KB |
| 04 | [ELK日志平台](04-企业级ELK-EFK日志分析平台.md) | Elasticsearch + Filebeat + Kibana + Kafka | 56KB |
| 05 | [MySQL高可用](05-企业级MySQL高可用集群-MGR-ProxySQL-备份.md) | MySQL MGR + ProxySQL + Xtrabackup | 50KB |
| 06 | [Redis集群](06-企业级Redis集群方案-Cluster-Sentinel-持久化.md) | Redis Cluster + Sentinel | 30KB |
| 07 | [Nginx高可用](07-企业级Nginx-Keepalived高可用.md) | Nginx + Keepalived + SSL + WAF | 59KB |
| 08 | [Ansible+Terraform](08-企业级Ansible-Terraform自动化运维.md) | Ansible + Terraform | 47KB |
| 09 | [K8s微服务网关](09-企业级K8s微服务网关-服务治理.md) | Kong + Istio + Jaeger | 55KB |
| 10 | [安全加固与等保](10-企业级安全加固与等保合规.md) | 主机加固 + K8s安全 + 等保三级 | 53KB |

**总计: 10个项目, 507KB**

---

## 📌 说明

- 所有密码均为示例占位符，生产环境请使用密钥管理工具
- 配置参数基于主流版本，实际使用前请确认版本兼容性
- 每个项目包含：架构设计、部署配置、故障案例、调优参数、灾备方案、成本估算、运维SOP

## 📜 License

[MIT](LICENSE)