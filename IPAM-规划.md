# 全局IP地址管理规划 (IPAM)

> 本文档定义所有项目的IP地址分配，避免网段冲突

## 网段划分

| 网段 | 用途 | 说明 |
|------|------|------|
| 10.10.0.0/24 | K8s Master节点 | 3台Master + HAProxy |
| 10.10.10.0/24 | K8s Worker节点 | 6台Worker |
| 10.10.20.0/24 | CI/CD服务器 | GitLab/Jenkins/SonarQube |
| 10.10.30.0/24 | 数据库服务器 | MySQL MGR + ProxySQL |
| 10.10.40.0/24 | 缓存服务器 | Redis Cluster |
| 10.10.50.0/24 | 入口服务器 | Nginx + Keepalived VIP |
| 10.10.60.0/24 | 监控服务器 | Prometheus/Grafana |
| 10.10.70.0/24 | 日志服务器 | ELK/EFK |
| 10.10.80.0/24 | 安全服务器 | 堡垒机/审计 |
| 10.10.90.0/24 | 备份服务器 | xtrabackup/etcd备份 |
| 10.10.100.0/24 | 预留 | 未来扩展 |

## VIP地址分配

| VIP | 用途 | Keepalived主节点 |
|-----|------|-----------------|
| 10.10.0.100 | K8s API Server | Master-01 |
| 10.10.50.100 | Nginx入口 | Nginx-01 |
| 10.10.30.100 | ProxySQL(待部署) | - |

## 注意事项

1. 所有服务器IP在分配前需确认无冲突
2. VIP地址从各网段末尾开始分配
3. 容器Pod网络使用Calico分配(192.168.0.0/16)
4. Service网络使用K8s默认(10.96.0.0/12)
