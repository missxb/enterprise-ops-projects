# 全局IP地址管理规划 (IPAM)

> 本文档定义所有项目的IP地址分配，与实际配置保持一致

## 网段划分

| 网段 | 用途 | 说明 |
|------|------|------|
| 10.10.11-13 | K8s Master节点 | 3台Master |
| 10.10.21-25 | K8s Worker节点 | 5台Worker |
| 10.10.31-33 | 数据库服务器 | MySQL MGR |
| 10.10.34-35 | ProxySQL | 读写分离 |
| 10.10.41-46 | Redis Cluster | 6节点 |
| 10.10.51-52 | Nginx入口 | Keepalived双主 |
| 10.10.61-63 | CI/CD | GitLab/Jenkins/SonarQube |
| 10.10.71-73 | 监控 | Prometheus/Grafana |
| 10.10.81-83 | 日志 | ELK/EFK |
| 10.10.91-92 | 安全 | 堡垒机/审计 |

## VIP地址分配

| VIP | 用途 | 说明 |
|-----|------|------|
| 10.10.100 | K8s API Server | HAProxy+Keepalived |
| 10.10.200 | Nginx入口 | 双主模式 |

## 网络CIDR

| 网络 | CIDR | 说明 |
|------|------|------|
| 物理网络 | 10.10.0.0/24 | 所有服务器 |
| Pod网络 | 10.244.0.0/16 | Calico分配 |
| Service网络 | 10.96.0.0/12 | K8s默认 |
