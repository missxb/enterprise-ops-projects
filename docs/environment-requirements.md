# 环境依赖说明

## 操作系统要求
| 组件 | 最低内核版本 | 推荐系统 | 备注 |
|------|-------------|----------|------|
| K8s 1.31 | 4.19+ | CentOS 7.9/Rocky 8/Ubuntu 22.04 | BGP模式需4.19+ |
| Calico 3.26 | 4.19+ | 同上 | 支持K8s 1.31 |
| Docker/Containerd | 3.10+ | 同上 | - |
| MySQL 8.0 | 3.10+ | CentOS 7.9+ | - |
| Redis 7.2 | 3.10+ | CentOS 7.9+ | - |
| ES 8.x | 4.14+ | CentOS 7.9+ | vm.max_map_count=262144 |

## 硬件要求
| 组件 | CPU | 内存 | 磁盘 | 网络 |
|------|-----|------|------|------|
| K8s Master | 8C+ | 32G+ | SSD 100G+ | 千兆 |
| K8s Worker | 8C+ | 32G+ | SSD 200G+ | 千兆 |
| MySQL | 8C+ | 32G+ | SSD 500G+ | 千兆 |
| Redis | 4C+ | 16G+ | SSD 100G+ | 千兆 |
| ES热节点 | 8C+ | 32G+ | NVMe 1T+ | 千兆 |
| ES冷节点 | 4C+ | 16G+ | HDD 4T+ | 千兆 |

## 网络要求
- 所有节点间网络互通
- Pod CIDR与Service CIDR不重叠
- MetalLB L2模式需要二层互通
- VIP漂移需要同一广播域

## 磁盘要求
- ES热节点: NVMe SSD(随机IO性能)
- MySQL: SSD(顺序写性能)
- Redis: SSD(持久化性能)
- 日志存储: HDD即可(顺序读写)

## 依赖服务
- NTP时间同步(所有节点)
- DNS解析(所有节点)
- SSH免密(运维节点到所有节点)
- 镜像仓库(所有节点可访问)
