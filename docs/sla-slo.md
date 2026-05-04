# SLO/SLI定义与错误预算

## 各组件SLO目标

| 组件 | 可用性SLO | 延迟SLO (P99) | 错误率SLO | SLI指标 |
|------|-----------|---------------|-----------|----------|
| K8s API Server | 99.95% | < 100ms | < 0.1% | apiserver_request_duration_seconds |
| MySQL MGR | 99.99% | < 10ms | < 0.01% | mysql_global_status_threads_connected |
| Redis Cluster | 99.95% | < 5ms | < 0.01% | redis_connected_clients |
| Elasticsearch | 99.9% | < 200ms | < 1% | elasticsearch_cluster_health_status |
| Nginx | 99.99% | < 50ms | < 0.1% | nginx_http_requests_total |
| Harbor | 99.9% | < 500ms | < 1% | harbor_project_total |

## SLI指标详细说明

### K8s API Server
- **可用性SLI**: apiserver_request_total{code!~"5.."} / apiserver_request_total
- **延迟SLI**: histogram_quantile(0.99, apiserver_request_duration_seconds_bucket)
- **错误率SLI**: apiserver_request_total{code=~"5.."} / apiserver_request_total

### MySQL MGR
- **可用性SLI**: mysql_global_status_up / mysql_global_status_up (3节点均存活)
- **延迟SLI**: mysql_global_status_seconds_running (P99)
- **错误率SLI**: mysql_global_status_threads_connected / expected_connections
- **数据一致性SLI**: mysql_group_replication_member_state (all_members_active)

### Redis Cluster
- **可用性SLI**: redis_up (所有节点)
- **延迟SLI**: redis_commands_duration_seconds_total (P99)
- **错误率SLI**: redis_rejected_connections_total / redis_connected_clients_total

### Elasticsearch
- **可用性SLI**: elasticsearch_cluster_health_status (green=1, yellow=0.5, red=0)
- **延迟SLI**: elasticsearch_index_search_query_total_duration_seconds (P99)
- **错误率SLI**: elasticsearch_cluster_health_unassigned_shards / total_shards

### Nginx
- **可用性SLI**: nginx_up
- **延迟SLI**: nginx_http_request_duration_seconds (P99)
- **错误率SLI**: nginx_http_requests_total{status=~"5.."} / nginx_http_requests_total

### Harbor
- **可用性SLI**: harbor_up
- **延迟SLI**: harbor_http_request_duration_seconds (P99)
- **错误率SLI**: harbor_http_requests_total{status=~"5.."} / harbor_http_requests_total

## 错误预算计算

错误预算 = (1 - SLO) × 时间周期

| 组件 | SLO | 每月允许停机 | 每周允许停机 | 每天允许停机 |
|------|-----|-------------|-------------|-------------|
| K8s API Server | 99.95% | 21.6分钟 | 5.04分钟 | 43.2秒 |
| MySQL MGR | 99.99% | 4.32分钟 | 1.01分钟 | 8.64秒 |
| Redis Cluster | 99.95% | 21.6分钟 | 5.04分钟 | 43.2秒 |
| Elasticsearch | 99.9% | 43.2分钟 | 10.08分钟 | 86.4秒 |
| Nginx | 99.99% | 4.32分钟 | 1.01分钟 | 8.64秒 |
| Harbor | 99.9% | 43.2分钟 | 10.08分钟 | 86.4秒 |

### 计算示例
- K8s SLO 99.95% → 每月允许停机: (1-0.9995) × 30天 × 24小时 = 0.36小时 = 21.6分钟
- MySQL SLO 99.99% → 每月允许停机: (1-0.9999) × 30天 × 24小时 = 0.072小时 = 4.32分钟

## 错误预算消耗告警策略

| 错误预算消耗 | 等级 | 动作 |
|-------------|------|------|
| < 25% | 正常 | 正常发布 |
| 25-50% | 注意 | 需要额外审查 |
| 50-80% | 警告 | 冻结非关键变更 |
| > 80% | 严重 | 只允许修复性变更 |
| 100% | 紧急 | 全面冻结，启动回滚评估 |

## 月度SLA违约赔偿

| 可用性等级 | 赔偿标准 |
|-----------|---------|
| < 99.9% | 赔偿当月费用10% |
| < 99% | 赔偿当月费用30% |
| < 95% | 赔偿当月费用100% |

## SLI采集频率

| 指标类型 | 采集间隔 | 保留期 |
|---------|---------|--------|
| 可用性 | 15秒 | 30天 |
| 延迟 | 15秒 | 30天 |
| 错误率 | 15秒 | 30天 |
| 吞吐量 | 15秒 | 30天 |
