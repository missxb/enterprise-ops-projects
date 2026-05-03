#!/bin/bash
# ELK健康检查脚本
set -euo pipefail

ES_HOST="${ES_HOST:-localhost:9200}"

echo "=== ELK健康检查 ==="

echo "1. Elasticsearch状态..."
curl -s "http://${ES_HOST}/_cluster/health?pretty" | grep -E '"status"|"number_of_nodes"'

echo "2. 索引状态..."
curl -s "http://${ES_HOST}/_cat/indices?v&s=index" | head -10

echo "3. Logstash状态..."
curl -s "http://localhost:9600/_node/stats?pretty" | grep '"status"' || echo "  ⚠️ Logstash未运行"

echo "4. Kibana状态..."
curl -s "http://localhost:5601/api/status" | grep '"overall"' || echo "  ⚠️ Kibana未运行"

echo "5. 磁盘使用..."
df -h /var/lib/elasticsearch

echo "✅ ELK检查完成"
