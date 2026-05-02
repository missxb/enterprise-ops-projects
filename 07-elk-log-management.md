# 企业级项目07: ELK Stack 日志收集与分析系统

## 📋 项目概述

完整的企业级日志收集、存储、分析、可视化方案，支持多源日志接入和实时分析。

**技术栈**: Elasticsearch + Logstash + Kibana + Filebeat + Metricbeat

---

## 🏗️ 架构图

```
┌─────────────────────────────────────────────────────────────────┐
│                    ELK Stack 日志分析架构                         │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  采集层 (Beats):                                                 │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐          │
│  │ Filebeat │ │Metricbeat│ │Heartbeat │ │Packetbeat│          │
│  │ (日志)   │ │ (指标)   │ │ (探针)   │ │ (网络)   │          │
│  └────┬─────┘ └────┬─────┘ └────┬─────┘ └────┬─────┘          │
│       │            │            │            │                  │
│  ═════╪════════════╪════════════╪════════════╪══════════════    │
│       │            │            │            │                  │
│  处理层:           │            │            │                  │
│  ┌────▼────────────▼────────────▼────────────▼──────────────┐   │
│  │                    Logstash                               │   │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐               │   │
│  │  │  Input   │──▶│ Filter   │──▶│ Output   │               │   │
│  │  │ (输入)   │  │ (过滤)   │  │ (输出)   │               │   │
│  │  └──────────┘  └──────────┘  └──────────┘               │   │
│  └──────────────────────┬───────────────────────────────────┘   │
│                          │                                      │
│  存储层:                │                                      │
│  ┌──────────────────────▼───────────────────────────────────┐   │
│  │              Elasticsearch Cluster                        │   │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐               │   │
│  │  │  Node-1  │  │  Node-2  │  │  Node-3  │               │   │
│  │  │  Master  │  │  Data    │  │  Data    │               │   │
│  │  │  +Ingest │  │  +ML     │  │  +Coordin│               │   │
│  │  └──────────┘  └──────────┘  └──────────┘               │   │
│  └──────────────────────┬───────────────────────────────────┘   │
│                          │                                      │
│  可视化层:              │                                      │
│  ┌──────────────────────▼───────────────────────────────────┐   │
│  │                    Kibana                                 │   │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐               │   │
│  │  │  Dashboard│  │  Discover│  │  Alerts  │               │   │
│  │  │  (仪表盘) │  │  (搜索)  │  │  (告警)  │               │   │
│  │  └──────────┘  └──────────┘  └──────────┘               │   │
│  └─────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

---

## 🚀 一键部署

### docker-compose.yml

```yaml
version: '3.8'

# ============================================
# ELK Stack 完整部署
# ============================================

services:
  # ========== Elasticsearch Node 1 (Master) ==========
  es01:
    image: docker.elastic.co/elasticsearch/elasticsearch:8.11.3
    container_name: es01
    restart: always
    environment:
      - node.name=es01
      - cluster.name=elk-cluster
      - cluster.initial_master_nodes=es01,es02,es03
      - discovery.seed_hosts=es01,es02,es03
      - bootstrap.memory_lock=true
      - xpack.security.enabled=true
      - xpack.security.enrollment.enabled=false
      - ELASTIC_PASSWORD=${ELASTIC_PASSWORD:-changeme}
      - xpack.security.http.ssl.enabled=false
      - "ES_JAVA_OPTS=-Xms4g -Xmx4g"
    ulimits:
      memlock:
        soft: -1
        hard: -1
      nofile:
        soft: 65536
        hard: 65536
    volumes:
      - es01-data:/usr/share/elasticsearch/data
    ports:
      - "9200:9200"
    networks:
      - elk
    deploy:
      resources:
        limits:
          cpus: '4'
          memory: 8G
    healthcheck:
      test: >
        curl -sf http://localhost:9200/_cluster/health?wait_for_status=yellow&timeout=5s
      interval: 30s
      timeout: 10s
      retries: 5

  # ========== Elasticsearch Node 2 (Data) ==========
  es02:
    image: docker.elastic.co/elasticsearch/elasticsearch:8.11.3
    container_name: es02
    restart: always
    environment:
      - node.name=es02
      - cluster.name=elk-cluster
      - cluster.initial_master_nodes=es01,es02,es03
      - discovery.seed_hosts=es01,es02,es03
      - bootstrap.memory_lock=true
      - xpack.security.enabled=true
      - xpack.security.enrollment.enabled=false
      - ELASTIC_PASSWORD=${ELASTIC_PASSWORD:-changeme}
      - xpack.security.http.ssl.enabled=false
      - "ES_JAVA_OPTS=-Xms4g -Xmx4g"
    ulimits:
      memlock:
        soft: -1
        hard: -1
      nofile:
        soft: 65536
        hard: 65536
    volumes:
      - es02-data:/usr/share/elasticsearch/data
    networks:
      - elk
    deploy:
      resources:
        limits:
          cpus: '4'
          memory: 8G

  # ========== Elasticsearch Node 3 (Data) ==========
  es03:
    image: docker.elastic.co/elasticsearch/elasticsearch:8.11.3
    container_name: es03
    restart: always
    environment:
      - node.name=es03
      - cluster.name=elk-cluster
      - cluster.initial_master_nodes=es01,es02,es03
      - discovery.seed_hosts=es01,es02,es03
      - bootstrap.memory_lock=true
      - xpack.security.enabled=true
      - xpack.security.enrollment.enabled=false
      - ELASTIC_PASSWORD=${ELASTIC_PASSWORD:-changeme}
      - xpack.security.http.ssl.enabled=false
      - "ES_JAVA_OPTS=-Xms4g -Xmx4g"
    ulimits:
      memlock:
        soft: -1
        hard: -1
      nofile:
        soft: 65536
        hard: 65536
    volumes:
      - es03-data:/usr/share/elasticsearch/data
    networks:
      - elk
    deploy:
      resources:
        limits:
          cpus: '4'
          memory: 8G

  # ========== Logstash ==========
  logstash:
    image: docker.elastic.co/logstash/logstash:8.11.3
    container_name: logstash
    restart: always
    environment:
      - "LS_JAVA_OPTS=-Xms2g -Xmx2g"
    volumes:
      - ./logstash/pipeline:/usr/share/logstash/pipeline:ro
      - ./logstash/config/logstash.yml:/usr/share/logstash/config/logstash.yml:ro
    ports:
      - "5044:5044"    # Beats input
      - "5000:5000"    # TCP input
      - "5000:5000/udp" # UDP input
      - "9600:9600"    # Monitoring API
    depends_on:
      es01:
        condition: service_healthy
    networks:
      - elk
    deploy:
      resources:
        limits:
          cpus: '2'
          memory: 4G

  # ========== Kibana ==========
  kibana:
    image: docker.elastic.co/kibana/kibana:8.11.3
    container_name: kibana
    restart: always
    environment:
      - ELASTICSEARCH_HOSTS=http://es01:9200
      - ELASTICSEARCH_USERNAME=kibana_system
      - ELASTICSEARCH_PASSWORD=${KIBANA_SYSTEM_PASSWORD:-changeme}
      - SERVER_NAME=kibana.company.com
      - SERVER_BASEPATH=/
      - XPACK_SECURITY_ENCRYPTIONKEY=${ENCRYPTION_KEY:-min-32-byte-long-encryption-key-here!!}
      - XPACK_ENCRYPTEDSAVEDOBJECTS_ENCRYPTIONKEY=${ENCRYPTION_KEY:-min-32-byte-long-encryption-key-here!!}
    ports:
      - "5601:5601"
    depends_on:
      es01:
        condition: service_healthy
    networks:
      - elk
    deploy:
      resources:
        limits:
          cpus: '2'
          memory: 4G

  # ========== Filebeat (日志采集) ==========
  filebeat:
    image: docker.elastic.co/beats/filebeat:8.11.3
    container_name: filebeat
    restart: always
    user: root
    volumes:
      - ./filebeat/filebeat.yml:/usr/share/filebeat/filebeat.yml:ro
      - /var/log:/var/log:ro
      - /var/lib/docker/containers:/var/lib/docker/containers:ro
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - filebeat-data:/usr/share/filebeat/data
    depends_on:
      es01:
        condition: service_healthy
    networks:
      - elk
    deploy:
      resources:
        limits:
          cpus: '1'
          memory: 1G

  # ========== Metricbeat (指标采集) ==========
  metricbeat:
    image: docker.elastic.co/beats/metricbeat:8.11.3
    container_name: metricbeat
    restart: always
    user: root
    volumes:
      - ./metricbeat/metricbeat.yml:/usr/share/metricbeat/metricbeat.yml:ro
      - /proc:/hostfs/proc:ro
      - /sys/fs/cgroup:/hostfs/sys/fs/cgroup:ro
      - /:/hostfs:ro
    depends_on:
      es01:
        condition: service_healthy
    networks:
      - elk
    deploy:
      resources:
        limits:
          cpus: '1'
          memory: 1G

  # ========== Heartbeat (探针监控) ==========
  heartbeat:
    image: docker.elastic.co/beats/heartbeat:8.11.3
    container_name: heartbeat
    restart: always
    volumes:
      - ./heartbeat/heartbeat.yml:/usr/share/heartbeat/heartbeat.yml:ro
    depends_on:
      es01:
        condition: service_healthy
    networks:
      - elk
    deploy:
      resources:
        limits:
          cpus: '0.5'
          memory: 512M

networks:
  elk:
    driver: bridge

volumes:
  es01-data:
  es02-data:
  es03-data:
  filebeat-data:
```

---

## 📋 配置文件

### .env

```bash
# ============================================
# ELK环境变量
# ============================================

# Elasticsearch密码
ELASTIC_PASSWORD=YourStr0ng!ElasticPass

# Kibana系统用户密码
KIBANA_SYSTEM_PASSWORD=YourStr0ng!KibanaPass

# 加密密钥 (至少32字符)
ENCRYPTION_KEY=min-32-byte-long-encryption-key-here!!
```

### logstash/config/logstash.yml

```yaml
# ============================================
# Logstash配置
# ============================================

http.host: "0.0.0.0"
http.port: 9600

# Pipeline配置
pipeline.workers: 4
pipeline.batch.size: 125
pipeline.batch.delay: 50

# 持久化队列
queue.type: persisted
queue.max_bytes: 4gb
queue.checkpoint.writes: 1024

# 监控
xpack.monitoring.enabled: true
xpack.monitoring.elasticsearch.hosts: ["http://es01:9200"]
xpack.monitoring.elasticsearch.username: "elastic"
xpack.monitoring.elasticsearch.password: "${ELASTIC_PASSWORD}"
```

### logstash/pipeline/logstash.conf

```ruby
# ============================================
# Logstash Pipeline配置
# ============================================

# ===== 输入 =====
input {
  # Beats输入 (Filebeat等)
  beats {
    port => 5044
    type => "beats"
  }
  
  # TCP输入 (应用日志)
  tcp {
    port => 5000
    codec => json_lines
    type => "tcp"
  }
  
  # UDP输入
  udp {
    port => 5000
    codec => json_lines
    type => "udp"
  }
}

# ===== 过滤器 =====
filter {
  # 解析Nginx访问日志
  if [type] == "nginx-access" {
    grok {
      match => {
        "message" => '%{IPORHOST:remote_addr} - %{DATA:remote_user} \[%{HTTPDATE:time_local}\] "%{WORD:method} %{URIPATHPARAM:request} HTTP/%{NUMBER:http_version}" %{NUMBER:status} %{NUMBER:body_bytes_sent} "%{DATA:http_referer}" "%{DATA:http_user_agent}" "%{DATA:x_forwarded_for}" %{NUMBER:request_time} %{NUMBER:upstream_response_time}'
      }
    }
    
    date {
      match => ["time_local", "dd/MMM/yyyy:HH:mm:ss Z"]
      target => "@timestamp"
    }
    
    mutate {
      convert => {
        "status" => "integer"
        "body_bytes_sent" => "integer"
        "request_time" => "float"
        "upstream_response_time" => "float"
      }
    }
    
    # IP地理定位
    geoip {
      source => "remote_addr"
      target => "geoip"
    }
    
    # User-Agent解析
    useragent {
      source => "http_user_agent"
      target => "ua"
    }
  }
  
  # 解析Nginx错误日志
  if [type] == "nginx-error" {
    grok {
      match => {
        "message" => '%{DATA:timestamp} \[%{DATA:level}\] %{NUMBER:pid}#%{NUMBER:tid}: (\*%{NUMBER:connection_id} )?%{GREEDYDATA:message}'
      }
    }
  }
  
  # 解析应用日志 (JSON格式)
  if [type] == "app" {
    json {
      source => "message"
      target => "app"
    }
    
    # 提取字段
    mutate {
      add_field => {
        "app_level" => "%{[app][level]}"
        "app_message" => "%{[app][message]}"
      }
    }
  }
  
  # 解析Java异常
  if [type] == "app" {
    multiline {
      pattern => "^%{TIMESTAMP_ISO8601}"
      negate => true
      what => "previous"
    }
  }
  
  # 清理字段
  mutate {
    remove_field => ["host", "agent", "ecs", "input"]
  }
}

# ===== 输出 =====
output {
  # 输出到Elasticsearch
  elasticsearch {
    hosts => ["http://es01:9200"]
    user => "elastic"
    password => "${ELASTIC_PASSWORD}"
    
    # 索引命名
    index => "%{[type]}-%{+YYYY.MM.dd}"
    
    # ILM (索引生命周期管理)
    ilm_enabled => true
    ilm_rollover_alias => "%{[type]}"
    ilm_pattern => "000001"
    ilm_policy => "log-policy"
  }
  
  # 输出到Kibana (调试用)
  # stdout {
  #   codec => rubydebug
  # }
}
```

### filebeat/filebeat.yml

```yaml
# ============================================
# Filebeat配置
# ============================================

filebeat.inputs:
  # 系统日志
  - type: log
    enabled: true
    paths:
      - /var/log/syslog
      - /var/log/auth.log
    fields:
      type: syslog
    fields_under_root: true

  # Nginx访问日志
  - type: log
    enabled: true
    paths:
      - /var/log/nginx/access.log
    fields:
      type: nginx-access
    fields_under_root: true

  # Nginx错误日志
  - type: log
    enabled: true
    paths:
      - /var/log/nginx/error.log
    fields:
      type: nginx-error
    fields_under_root: true

  # 应用日志
  - type: log
    enabled: true
    paths:
      - /var/log/app/*.log
    fields:
      type: app
    fields_under_root: true
    json.keys_under_root: true
    json.add_error_key: true

  # Docker容器日志
  - type: container
    enabled: true
    paths:
      - /var/lib/docker/containers/*/*-json.log
    fields:
      type: docker
    fields_under_root: true

# ===== 处理器 =====
processors:
  - add_host_metadata:
      when.not.contains.tags: forwarded
  - add_docker_metadata:
      host: "unix:///var/run/docker.sock"
  - add_kubernetes_metadata:
      host: ${NODE_NAME}

# ===== 输出到Logstash =====
output.logstash:
  hosts: ["logstash:5044"]
  bulk_max_size: 2048
  
  # 负载均衡
  loadbalance: true

# ===== 监控 =====
monitoring.enabled: false
```

### metricbeat/metricbeat.yml

```yaml
# ============================================
# Metricbeat配置
# ============================================

metricbeat.modules:
  # 系统指标
  - module: system
    metricsets:
      - cpu
      - load
      - memory
      - network
      - process
      - process_summary
      - diskio
      - filesystem
      - fsstat
    period: 10s
    processes: ['.*']
    cpu.metrics: ["percentages", "normalized_percentages"]

  # Docker指标
  - module: docker
    metricsets:
      - container
      - cpu
      - diskio
      - healthcheck
      - info
      - memory
      - network
    hosts: ["unix:///var/run/docker.sock"]
    period: 10s

  # Nginx指标
  - module: nginx
    metricsets:
      - stubstatus
    period: 10s
    hosts: ["http://nginx:8080"]
    server_status_path: "/stub_status"

  # MySQL指标
  - module: mysql
    metricsets:
      - status
      - galera_status
    period: 10s
    hosts: ["tcp(mysql:3306)"]
    username: "exporter"
    password: "${MYSQL_EXPORTER_PASSWORD}"

  # Redis指标
  - module: redis
    metricsets:
      - info
      - keyspace
    period: 10s
    hosts: ["redis://redis:6379"]
    password: "${REDIS_PASSWORD}"

# ===== 输出到Elasticsearch =====
output.elasticsearch:
  hosts: ["http://es01:9200"]
  username: "elastic"
  password: "${ELASTIC_PASSWORD}"
  protocol: "http"
  
  # 索引模板
  index.name.prefix: "metricbeat"
  
  # ILM
  ilm.enabled: true
  ilm.rollover_alias: "metricbeat"
  ilm.pattern: "000001"
  ilm.policy_name: "metricbeat-policy"

# ===== 监控 =====
monitoring.enabled: false
```

### heartbeat/heartbeat.yml

```yaml
# ============================================
# Heartbeat探针监控配置
# ============================================

heartbeat.monitors:
  # HTTP探针
  - type: http
    id: my-http-service
    name: HTTP Service
    hosts: ["http://app:8000/health"]
    schedule: "@every 10s"
    timeout: 5s
    
    check.response:
      status: 200
      body:
        - '"status":"ok"'

  # TCP探针
  - type: tcp
    id: my-tcp-service
    name: TCP Service
    hosts: ["mysql:3306"]
    schedule: "@every 10s"
    timeout: 5s

  # ICMP探针
  - type: icmp
    id: my-icmp-service
    name: ICMP Service
    hosts: ["app"]
    schedule: "@every 30s"
    timeout: 5s

# ===== 输出到Elasticsearch =====
output.elasticsearch:
  hosts: ["http://es01:9200"]
  username: "elastic"
  password: "${ELASTIC_PASSWORD}"
  
  index.name.prefix: "heartbeat"
  ilm.enabled: true
  ilm.rollover_alias: "heartbeat"
  ilm.pattern: "000001"
  ilm.policy_name: "heartbeat-policy"

monitoring.enabled: false
```

---

## 📊 Kibana仪表盘

### 常用Dashboard配置

#### 1. Nginx访问分析仪表盘

```json
{
  "title": "Nginx Access Analytics",
  "objects": [
    {
      "id": "nginx-overview",
      "type": "visualization",
      "attributes": {
        "title": "请求量趋势",
        "visState": {
          "title": "请求量趋势",
          "type": "line",
          "aggs": [
            {
              "id": "1",
              "enabled": true,
              "type": "count",
              "params": {},
              "schema": "metric"
            },
            {
              "id": "2",
              "enabled": true,
              "type": "date_histogram",
              "params": {
                "field": "@timestamp",
                "interval": "1h"
              },
              "schema": "segment"
            }
          ]
        }
      }
    },
    {
      "id": "status-codes",
      "type": "visualization",
      "attributes": {
        "title": "HTTP状态码分布",
        "visState": {
          "title": "HTTP状态码分布",
          "type": "pie",
          "aggs": [
            {
              "id": "1",
              "enabled": true,
              "type": "count",
              "params": {},
              "schema": "metric"
            },
            {
              "id": "2",
              "enabled": true,
              "type": "terms",
              "params": {
                "field": "status",
                "size": 10
              },
              "schema": "segment"
            }
          ]
        }
      }
    }
  ]
}
```

### 常用KQL查询

```
# 所有错误日志
status: 500 or status: 502 or status: 503

# 特定IP的请求
remote_addr: "192.168.1.100"

# 响应时间大于2秒的请求
request_time > 2

# 特定API的请求
request: "/api/v1/users"

# 慢查询日志
type: "app" AND app_level: "ERROR"

# 容器日志
type: "docker" AND container.name: "fastapi-app"

# 最近1小时的错误
status: 5* and @timestamp >= now-1h
```

### 告警规则

```
# Kibana告警配置

1. 高错误率告警
   - 条件: 5xx错误率 > 5%
   - 时间窗口: 5分钟
   - 通知: 钉钉/邮件

2. 响应时间告警
   - 条件: P95响应时间 > 2秒
   - 时间窗口: 5分钟
   - 通知: 钉钉/邮件

3. 新错误类型告警
   - 条件: 出现新的错误消息
   - 时间窗口: 1小时
   - 通知: 邮件

4. 磁盘空间告警
   - 条件: Elasticsearch磁盘使用率 > 85%
   - 通知: 钉钉/邮件
```

---

## 🔧 运维手册

### 常用命令

```bash
# ===== Elasticsearch =====
# 查看集群健康
curl -u elastic:${ELASTIC_PASSWORD} http://localhost:9200/_cluster/health?pretty

# 查看节点状态
curl -u elastic:${ELASTIC_PASSWORD} http://localhost:9200/_cat/nodes?v

# 查看索引
curl -u elastic:${ELASTIC_PASSWORD} http://localhost:9200/_cat/indices?v

# 查看分片分配
curl -u elastic:${ELASTIC_PASSWORD} http://localhost:9200/_cat/shards?v

# 强制合并段
curl -X POST -u elastic:${ELASTIC_PASSWORD} http://localhost:9200/_forcemerge?max_num_segments=1

# 清理缓存
curl -X POST -u elastic:${ELASTIC_PASSWORD} http://localhost:9200/_cache/clear

# ===== Logstash =====
# 查看Pipeline状态
curl http://localhost:9600/_node/stats/pipelines?pretty

# 热重载配置
curl -X PUT http://localhost:9600/_node/config?path=pipeline/logstash.conf

# ===== Kibana =====
# 导出Dashboard
curl -X POST "http://localhost:5601/api/saved_objects/_export" \
  -H "kbn-xsrf: true" \
  -H "Content-Type: application/json" \
  -d '{"objects":[{"type":"dashboard","id":"your-dashboard-id"}]}'

# 导入Dashboard
curl -X POST "http://localhost:5601/api/saved_objects/_import" \
  -H "kbn-xsrf: true" \
  --form file=@dashboard_export.ndjson
```

### ILM (索引生命周期管理)

```bash
# 创建ILM策略
curl -X PUT -u elastic:${ELASTIC_PASSWORD} \
  "http://localhost:9200/_ilm/policy/log-policy" \
  -H 'Content-Type: application/json' \
  -d '{
    "policy": {
      "phases": {
        "hot": {
          "min_age": "0ms",
          "actions": {
            "rollover": {
              "max_primary_shard_size": "30gb",
              "max_age": "1d"
            },
            "set_priority": {
              "priority": 100
            }
          }
        },
        "warm": {
          "min_age": "7d",
          "actions": {
            "shrink": {
              "number_of_shards": 1
            },
            "forcemerge": {
              "max_num_segments": 1
            },
            "set_priority": {
              "priority": 50
            }
          }
        },
        "cold": {
          "min_age": "30d",
          "actions": {
            "set_priority": {
              "priority": 0
            }
          }
        },
        "delete": {
          "min_age": "90d",
          "actions": {
            "delete": {}
          }
        }
      }
    }
  }'
```

### 性能优化

| 配置项 | 建议值 | 说明 |
|-------|--------|------|
| JVM堆内存 | 物理内存50%，最大31G | 避免超过32G指针压缩失效 |
| 分片数 | 每个分片20-40GB | 过多分片影响性能 |
| 副本数 | 1-2 | 生产环境至少1个副本 |
| 刷新间隔 | 30s | 非实时场景可调大 |
| Translog | async | 提高写入性能 |

---

**作者**: 企业级运维项目集
**版本**: 1.0.0
**更新时间**: 2026-05-02
