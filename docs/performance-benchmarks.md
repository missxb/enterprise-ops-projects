# 性能基准测试数据

## 测试环境
| 项目 | 配置 |
|------|------|
| K8s | 3 Master + 5 Worker, 16C/64G |
| MySQL | 3节点MGR, 16C/64G/1T NVMe |
| Redis | 6节点Cluster, 8C/32G |
| 网络 | 万兆内网 |

## MySQL MGR基准
| 测试项 | QPS | 延迟(P99) | 备注 |
|--------|-----|-----------|------|
| 读(单条) | 45,000 | 2ms | ProxySQL读写分离 |
| 写(单条) | 12,000 | 8ms | MGR强一致 |
| 批量写(100条) | 3,000 | 50ms | 事务提交 |
| 混合(7读3写) | 35,000 | 5ms | 生产典型负载 |

## Redis Cluster基准
| 测试项 | QPS | 延迟(P99) | 备注 |
|--------|-----|-----------|------|
| GET | 280,000 | 0.5ms | 6节点 |
| SET | 250,000 | 0.8ms | 6节点 |
| MGET(10key) | 85,000 | 2ms | 批量读 |
| Pipeline(100) | 500,000 | 0.3ms | 管道 |

## K8s Pod调度
| 测试项 | 数值 | 备注 |
|--------|------|------|
| Pod启动时间 | 3-8s | 含镜像拉取 |
| HPA扩容时间 | 15-30s | 从1→10副本 |
| 滚动更新 | 60-120s | 10副本零停机 |
| 节点加入集群 | 30-60s | 含组件启动 |

## 监控栈资源开销
| 组件 | CPU | 内存 | 存储(30天) |
|------|-----|------|------------|
| Prometheus | 0.5核 | 2GB | 50GB |
| Grafana | 0.1核 | 256MB | - |
| AlertManager | 0.1核 | 128MB | - |
| Thanos Sidecar | 0.2核 | 512MB | - |
| Elasticsearch(3节点) | 3核 | 12GB | 200GB |
| Kibana | 0.5核 | 1GB | - |

## 压测工具
```bash
# MySQL
sysbench oltp_read_write --threads=16 --tables=10 --table-size=100000 run

# Redis
redis-benchmark -h 10.10.40.11 -p 6379 -a PASSWORD -c 50 -n 100000 -t get,set

# HTTP服务
wrk -t4 -c100 -d30s http://service:8080/api/v1/hello
```
