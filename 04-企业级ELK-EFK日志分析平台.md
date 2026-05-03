1|# 企业级ELK/EFK日志分析平台
     2|
     3|> 完整实现企业级日志收集、存储、检索、可视化全链路
     4|> 覆盖: Elasticsearch集群 + Filebeat + Kibana + ILM生命周期 + 安全加固
     5|
     6|---
     7|
     8|## 一、架构总览
     9|
    10|```
    11|应用Pod ──▶ Filebeat(DaemonSet) ──▶ Kafka(可选缓冲) ──▶ Logstash ──▶ Elasticsearch ──▶ Kibana
    12|                                      │                                      │
    13|                                      │              ┌────────────────────────┘
    14|                                      │              ▼
    15|                                      │    ILM生命周期管理
    16|                                      │    热节点(SSD) → 温节点(HDD) → 冷节点(归档)
    17|                                      │
    18|                                      └──▶ 直连ES(轻量方案,跳过Logstash)
    19|```
    20|
    21|---
    22|
    23|## 二、服务器规划
    24|
    25|| 服务 | 数量 | 配置 | 用途 |
    26||------|------|------|------|
    27|| Elasticsearch Master | 3 | 8C/32G/200G SSD | 集群管理+协调 |
    28|| Elasticsearch Data-Hot | 3 | 16C/64G/2T NVMe | 热数据(7天) |
    29|| Elasticsearch Data-Warm | 2 | 8C/32G/4T HDD | 温数据(30天) |
    30|| Elasticsearch Data-Cold | 1 | 4C/16G/10T HDD | 冷数据(90天) |
    31|| Kibana | 2 | 4C/8G/50G | 可视化 |
    32|| Logstash | 3 | 8C/16G/100G | 日志转换 |
    33|| Filebeat | DaemonSet | - | 日志采集 |
    34|
    35|---
    36|
    37|## 三、Elasticsearch集群部署
    38|
    39|```yaml
    40|# elasticsearch-statefulset.yaml
    41|---
    42|apiVersion: v1
    43|kind: ConfigMap
    44|metadata:
    45|  name: elasticsearch-config
    46|  namespace: logging
    47|data:
    48|  elasticsearch.yml: |
    49|    cluster.name: enterprise-logs
    50|    node.name: ${NODE_NAME}
    51|    node.roles: [master]
    52|    path.data: /usr/share/elasticsearch/data
    53|    path.logs: /usr/share/elasticsearch/logs
    54|    network.host: 0.0.0.0
    55|    discovery.seed_hosts:
    56|      - es-master-0.es-master.logging.svc.cluster.local
    57|      - es-master-1.es-master.logging.svc.cluster.local
    58|      - es-master-2.es-master.logging.svc.cluster.local
    59|    cluster.initial_master_nodes:
    60|      - es-master-0
    61|      - es-master-1
    62|      - es-master-2
    63|    xpack.security.enabled: true
    64|    xpack.security.transport.ssl.enabled: true
    65|    xpack.security.transport.ssl.verification_mode: certificate
    66|    xpack.security.transport.ssl.keystore.path: /usr/share/elasticsearch/config/certs/transport.p12
    67|    xpack.security.transport.ssl.truststore.path: /usr/share/elasticsearch/config/certs/transport.p12
    68|    xpack.security.http.ssl.enabled: true
    69|    xpack.security.http.ssl.keystore.path: /usr/share/elasticsearch/config/certs/http.p12
    70|
    71|  jvm.options: |
    72|    -Xms16g
    73|    -Xmx16g
    74|    -XX:+UseG1GC
    75|    -XX:G1HeapRegionSize=4m
    76|    -XX:InitiatingHeapOccupancyPercent=30
    77|    -XX:G1ReservePercent=15
    78|    -XX:MaxGCPauseMillis=200
    79|    -Djava.io.tmpdir=/tmp
    80|    -XX:+HeapDumpOnOutOfMemoryError
    81|    -XX:HeapDumpPath=/tmp/heapdump.hprof
    82|
    83|---
    84|apiVersion: apps/v1
    85|kind: StatefulSet
    86|metadata:
    87|  name: es-master
    88|  namespace: logging
    89|spec:
    90|  serviceName: es-master
    91|  replicas: 3
    92|  selector:
    93|    matchLabels:
    94|      app: elasticsearch
    95|      role: master
    96|  template:
    97|    metadata:
    98|      labels:
    99|        app: elasticsearch
   100|        role: master
   101|    spec:
   102|      initContainers:
   103|        # 设置vm.max_map_count
   104|        - name: sysctl
   105|          image: busybox
   106|          command: ['sysctl', '-w', 'vm.max_map_count=262144']
   107|          securityContext:
   108|            privileged: true
   109|        # 设置文件描述符
   110|        - name: ulimit
   111|          image: busybox
   112|          command: ['sh', '-c', 'ulimit -n 65536']
   113|          securityContext:
   114|            privileged: true
   115|      containers:
   116|        - name: elasticsearch
   117|          image: elasticsearch:8.11.3
   118|          ports:
   119|            - containerPort: 9200  # ES端口
   120|              name: http
   121|            - containerPort: 9300
   122|              name: transport
   123|          env:
   124|            - name: NODE_NAME
   125|              valueFrom:
   126|                fieldRef:
   127|                  fieldPath: metadata.name
   128|            - name: ES_JAVA_OPTS
   129|              value: "-Xms16g -Xmx16g"
   130|            - name: ELASTIC_PASSWORD
   131|              valueFrom:
   132|                secretKeyRef:
   133|                  name: elasticsearch-credentials
   134|                  key: elastic
   135|          resources:
   136|            requests:
   137|              cpu: "4"
   138|              memory: 32Gi
   139|            limits:
   140|              cpu: "8"
   141|              memory: 32Gi
   142|          volumeMounts:
   143|            - name: elasticsearch-data
   144|              mountPath: /usr/share/elasticsearch/data
   145|            - name: config
   146|              mountPath: /usr/share/elasticsearch/config/elasticsearch.yml
   147|              subPath: elasticsearch.yml
   148|          readinessProbe:
   149|            httpGet:
   150|              path: /_cluster/health?local=true
   151|              port: 9200  # ES端口
   152|              scheme: https
   153|            initialDelaySeconds: 30
   154|            periodSeconds: 10
   155|  
   156|  volumeClaimTemplates:
   157|    - metadata:
   158|        name: elasticsearch-data
   159|      spec:
   160|        accessModes: ["ReadWriteOnce"]
   161|        storageClassName: local-ssd
   162|        resources:
   163|          requests:
   164|            storage: 200Gi
   165|
   166|---
   167|# Data Hot节点 (NVMe SSD)
   168|apiVersion: apps/v1
   169|kind: StatefulSet
   170|metadata:
   171|  name: es-data-hot
   172|  namespace: logging
   173|spec:
   174|  serviceName: es-data-hot
   175|  replicas: 3
   176|  selector:
   177|    matchLabels:
   178|      app: elasticsearch
   179|      role: data-hot
   180|  template:
   181|    spec:
   182|      containers:
   183|        - name: elasticsearch
   184|          image: elasticsearch:8.11.3
   185|          env:
   186|            - name: NODE_ROLES
   187|              value: "data_hot,ingest"
   188|            - name: ES_JAVA_OPTS
   189|              value: "-Xms28g -Xmx28g"
   190|          resources:
   191|            requests:
   192|              cpu: "8"
   193|              memory: 40Gi
   194|            limits:
   195|              cpu: "16"
   196|              memory: 64Gi
   197|  
   198|  volumeClaimTemplates:
   199|    - metadata:
   200|        name: elasticsearch-data
   201|      spec:
   202|        storageClassName: local-nvme
   203|        resources:
   204|          requests:
   205|            storage: 2Ti
   206|```
   207|
   208|---
   209|
   210|## 四、ILM生命周期管理
   211|
   212|```json
   213|// PUT _ilm/policy/enterprise-logs-policy
   214|{
   215|  "policy": {
   216|    "phases": {
   217|      "hot": {
   218|        "min_age": "0ms",
   219|        "actions": {
   220|          "rollover": {
   221|            "max_primary_shard_size": "50gb",
   222|            "max_age": "1d"
   223|          },
   224|          "set_priority": {
   225|            "priority": 100
   226|          }
   227|        }
   228|      },
   229|      "warm": {
   230|        "min_age": "7d",
   231|        "actions": {
   232|          "shrink": {
   233|            "number_of_shards": 1
   234|          },
   235|          "forcemerge": {
   236|            "max_num_segments": 1
   237|          },
   238|          "set_priority": {
   239|            "priority": 50
   240|          },
   241|          "migrate": {
   242|            "enabled": true
   243|          }
   244|        }
   245|      },
   246|      "cold": {
   247|        "min_age": "30d",
   248|        "actions": {
   249|          "set_priority": {
   250|            "priority": 0
   251|          },
   252|          "searchable_snapshot": { "snapshot_repository": "cold-backup" }  # [已修复] freeze在ES 8.x已废弃
   253|        }
   254|      },
   255|      "delete": {
   256|        "min_age": "90d",
   257|        "actions": {
   258|          "delete": {}
   259|        }
   260|      }
   261|    }
   262|  }
   263|}
   264|```
   265|
   266|```bash
   267|# 创建Index Template
   268|curl -X PUT "http://es-master-0:9200/_index_template/enterprise-logs" -H 'Content-Type: application/json' -d'
   269|{
   270|  "index_patterns": ["enterprise-logs-*"],
   271|  "template": {
   272|    "settings": {
   273|      "number_of_shards": 3,
   274|      "number_of_replicas": 1,
   275|      "index.lifecycle.name": "enterprise-logs-policy",
   276|      "index.lifecycle.rollover_alias": "enterprise-logs",
   277|      "index.routing.allocation.require.node_role": "data_hot"
   278|    },
   279|    "mappings": {
   280|      "properties": {
   281|        "@timestamp": { "type": "date" },
   282|        "message": { "type": "text" },
   283|        "level": { "type": "keyword" },
   284|        "service": { "type": "keyword" },
   285|        "namespace": { "type": "keyword" },
   286|        "pod": { "type": "keyword" },
   287|        "container": { "type": "keyword" },
   288|        "host": { "type": "keyword" },
   289|        "trace_id": { "type": "keyword" },
   290|        "method": { "type": "keyword" },
   291|        "path": { "type": "keyword" },
   292|        "status_code": { "type": "integer" },
   293|        "response_time": { "type": "float" },
   294|        "client_ip": { "type": "ip" },
   295|        "user_agent": { "type": "text" }
   296|      }
   297|    }
   298|  },
   299|  "priority": 200
   300|}'
   301|```
   302|
   303|---
   304|
   305|## 五、Filebeat DaemonSet
   306|
   307|```yaml
   308|# filebeat-daemonset.yaml
   309|---
   310|apiVersion: apps/v1
   311|kind: DaemonSet
   312|metadata:
   313|  name: filebeat
   314|  namespace: logging
   315|spec:
   316|  selector:
   317|    matchLabels:
   318|      app: filebeat
   319|  template:
   320|    metadata:
   321|      labels:
   322|        app: filebeat
   323|    spec:
   324|      serviceAccountName: filebeat
   325|      terminationGracePeriodSeconds: 30
   326|      containers:
   327|        - name: filebeat
   328|          image: elastic/filebeat:8.11.3
   329|          args: ["-c", "/etc/filebeat/filebeat.yml", "-e"]
   330|          securityContext:
   331|            runAsUser: 0  # Filebeat需要root访问日志目录，生产环境考虑非root方案
   332|          resources:
   333|            requests:
   334|              cpu: 100m
   335|              memory: 200Mi
   336|            limits:
   337|              cpu: 500m
   338|              memory: 500Mi
   339|          volumeMounts:
   340|            - name: config
   341|              mountPath: /etc/filebeat/filebeat.yml
   342|              subPath: filebeat.yml
   343|            - name: varlog
   344|              mountPath: /var/log
   345|              readOnly: true
   346|            - name: containers
   347|              mountPath: /var/log/pods  # [已修复] containerd环境请改为/var/log/pods/
   348|              readOnly: true
   349|            - name: data
   350|              mountPath: /usr/share/filebeat/data
   351|          env:
   352|            - name: NODE_NAME
   353|              valueFrom:
   354|                fieldRef:
   355|                  fieldPath: spec.nodeName
   356|      
   357|      volumes:
   358|        - name: config
   359|          configMap:
   360|            name: filebeat-config
   361|        - name: varlog
   362|          hostPath:
   363|            path: /var/log
   364|        - name: containers
   365|          hostPath:
   366|            path: /var/log/pods
   367|        - name: data
   368|          emptyDir: {}
   369|
   370|---
   371|apiVersion: v1
   372|kind: ConfigMap
   373|metadata:
   374|  name: filebeat-config
   375|  namespace: logging
   376|data:
   377|  filebeat.yml: |
   378|    filebeat.inputs:
   379|      # K8s容器日志
   380|      - type: container
   381|        enabled: true
   382|        paths:
   383|          - /var/log/containers/*.log
   384|        processors:
   385|          - add_kubernetes_metadata:
   386|              host: ${NODE_NAME}
   387|              matchers:
   388|                - logs_path:
   389|                    logs_path: "/var/log/containers/"
   390|          - decode_json_fields:
   391|              fields: ["message"]
   392|              target: ""
   393|              overwrite_keys: true
   394|              add_error_key: true
   395|      
   396|      # Nginx日志
   397|      - type: container
   398|        enabled: true
   399|        paths:
   400|          - /var/log/containers/*nginx*.log
   401|        processors:
   402|          - add_kubernetes_metadata:
   403|              host: ${NODE_NAME}
   404|          - dissect:
   405|              tokenizer: '%{client_ip} - %{remote_user} [%{timestamp}] "%{method} %{path} HTTP/%{http_version}" %{status_code} %{body_bytes_sent} "%{referrer}" "%{user_agent}" %{response_time}'
   406|              field: "message"
   407|              target_prefix: "nginx"
   408|      
   409|      # Java应用日志（多行合并）
   410|      - type: container
   411|        enabled: true
   412|        paths:
   413|          - /var/log/containers/*java*.log
   414|        multiline.type: pattern
   415|        multiline.pattern: '^\d{4}-\d{2}-\d{2}'
   416|        multiline.negate: true
   417|        multiline.match: after
   418|        multiline.max_lines: 500
   419|        processors:
   420|          - add_kubernetes_metadata:
   421|              host: ${NODE_NAME}
   422|    
   423|    # 输出到Elasticsearch
   424|    output.elasticsearch:
   425|      hosts: ["https://es-data-hot-0.es-data-hot.logging:9200"]
   426|      username: "elastic"
   427|      password: "${ELASTIC_PASSWORD}"
   428|      ssl.certificate_authorities: ["/etc/filebeat/certs/ca.crt"]
   429|      index: "enterprise-logs-%{+yyyy.MM.dd}"
   430|      bulk_max_size: 5000
   431|      worker: 4
   432|      loadbalance: true
   433|    
   434|    # 处理器
   435|    processors:
   436|      - add_host_metadata:
   437|          when.not.contains.tags: forwarded
   438|      - add_cloud_metadata: ~
   439|      - add_docker_metadata: ~
   440|      - drop_fields:
   441|          fields: ["agent.ephemeral_id", "agent.id"]
   442|      
   443|    # 监控
   444|    monitoring.enabled: true
   445|    monitoring.elasticsearch:
   446|      hosts: ["https://es-master-0:9200"]
   447|```
   448|
   449|---
   450|
   451|## 六、Kibana部署
   452|
   453|```yaml
   454|# kibana-deployment.yaml
   455|---
   456|apiVersion: apps/v1
   457|kind: Deployment
   458|metadata:
   459|  name: kibana
   460|  namespace: logging
   461|spec:
   462|  replicas: 2
   463|  selector:
   464|    matchLabels:
   465|      app: kibana
   466|  template:
   467|    spec:
   468|      containers:
   469|        - name: kibana
   470|          image: kibana:8.11.3
   471|          env:
   472|            - name: ELASTICSEARCH_HOSTS
   473|              value: '["https://es-master-0:9200","https://es-master-1:9200","https://es-master-2:9200"]'
   474|            - name: ELASTICSEARCH_USERNAME
   475|              value: "kibana_system"
   476|            - name: ELASTICSEARCH_PASSWORD
   477|              valueFrom:
   478|                secretKeyRef:
   479|                  name: elasticsearch-credentials
   480|                  key: kibana_system
   481|            - name: SERVER_NAME
   482|              value: "kibana.internal.com"
   483|          ports:
   484|            - containerPort: 5601
   485|          resources:
   486|            requests:
   487|              cpu: "1"
   488|              memory: 2Gi
   489|            limits:
   490|              cpu: "2"
   491|              memory: 4Gi
   492|          readinessProbe:
   493|            httpGet:
   494|              path: /api/status
   495|              port: 5601
   496|            initialDelaySeconds: 30
   497|            periodSeconds: 10
   498|
   499|---
   500|apiVersion: v1
   501|

---

> ⚠️ **安全声明**: 本文档中的密码(如${MYSQL_ROOT_PASSWORD}、${HARBOR_ADMIN_PASSWORD}等)均为示例占位符。
> 生产环境必须使用密钥管理工具(Vault/K8s Secrets/环境变量)管理敏感信息，
> 切勿将真实密码硬编码在配置文件或脚本中。

## 九、Elasticsearch性能调优

### 9.1 JVM调优

```bash
# /etc/elasticsearch/jvm.options
# 堆内存: 不超过物理内存的50%，不超过32GB(压缩指针上限)
-Xms16g
-Xmx16g

# GC配置(G1GC)
-XX:+UseG1GC
-XX:G1HeapRegionSize=4m
-XX:InitiatingHeapOccupancyPercent=30
-XX:G1ReservePercent=15
-XX:MaxGCPauseMillis=200

# 内存锁定(防止swap)
-XX:+AlwaysPreTouch
-XX:+ExitOnOutOfMemoryError
-XX:HeapDumpPath=/tmp/heapdump.hprof
```

### 9.2 索引优化

```json
// 索引模板优化
PUT _index_template/logs-template
{
  "index_patterns": ["logs-*"],
  "template": {
    "settings": {
      "number_of_shards": 3,
      "number_of_replicas": 1,
      "refresh_interval": "5s",
      "translog.durability": "async",
      "translog.flush_threshold_size": "512mb",
      "codec": "best_compression",
      "routing_allocation.require.node_role": "data_hot"
    },
    "mappings": {
      "dynamic": "strict",
      "properties": {
        "@timestamp": { "type": "date" },
        "message": { "type": "text", "analyzer": "ik_max_word" },
        "level": { "type": "keyword" },
        "service": { "type": "keyword" },
        "trace_id": { "type": "keyword" },
        "response_time": { "type": "float" },
        "status_code": { "type": "short" }
      }
    }
  },
  "priority": 200
}
```

### 9.3 查询优化

```json
// 使用filter代替query(可缓存)
{
  "query": {
    "bool": {
      "filter": [
        { "term": { "service": "user-service" } },
        { "range": { "@timestamp": { "gte": "now-1h" } } }
      ]
    }
  }
}

// 使用routing减少搜索范围
GET /logs-user-service/_search?routing=user-service
{
  "query": { "match": { "message": "error" } }
}

// 使用source filtering减少网络传输
GET /logs-*/_search
{
  "_source": ["@timestamp", "message", "level"],
  "query": { "term": { "level": "ERROR" } }
}
```

---

## 十、真实故障案例

### 案例1: Elasticsearch集群RED状态

**故障**: 集群状态变为RED，部分索引不可用

**原因**: 2个数据节点同时宕机，主分片丢失

**解决**:
```bash
# 1. 检查集群状态
curl -s 'http://es-master:9200/_cluster/health?pretty'

# 2. 查看未分配分片
curl -s 'http://es-master:9200/_cluster/allocation/explain?pretty'

# 3. 强制分配分片(数据会丢失)
curl -X POST 'http://es-master:9200/_cluster/reroute' -H 'Content-Type: application/json' -d '{
  "commands": [{
    "allocate_stale_primary": {
      "index": "logs-2024.01.15",
      "shard": 0,
      "node": "es-data-hot-01",
      "accept_data_loss": true
    }
  }]
}'

# 4. 恢复节点后自动恢复副本分片
```

### 案例2: Filebeat日志丢失

**故障**: Kibana中发现日志有间隙，部分日志丢失

**原因**: Filebeat背压(backpressure)导致丢弃日志

**解决**:
```yaml
# Filebeat配置优化
filebeat.inputs:
  - type: container
    paths:
      - /var/log/containers/*.log
    # 增大harvest buffer
    harvester_buffer_size: 65536
    # 增大max_bytes
    max_bytes: 10485760  # 10MB
    
# 增大队列
queue.mem:
  events: 4096
  flush.min_events: 512
  flush.timeout: 5s

# 增大bulk大小
output.elasticsearch:
  bulk_max_size: 10000
  worker: 4
```

### 案例3: Kibana查询超时

**故障**: Kibana Discover页面加载超过30秒

**原因**: 索引数据量太大，查询范围过广

**解决**:
```bash
# 1. 缩短默认时间范围
# Kibana → Advanced Settings → timepicker:timeDefaults → 最大15分钟

# 2. 优化索引生命周期
# 热数据保留7天，温数据30天，冷数据90天

# 3. 创建数据视图时限制字段
# 只索引需要搜索的字段，其他字段设置 "index": false

# 4. 使用date_nanos代替date(如果需要更高精度)
```

---

## 十一、容量规划

| 指标 | 估算公式 | 示例 |
|------|---------|------|
| 索引大小 | 原始日志 × 1.1(压缩) | 100GB原始 → 110GB索引 |
| 分片大小 | 单分片20-50GB | 110GB → 3-5个分片 |
| 热节点存储 | 7天日志 × 副本 | 100GB/天 × 7 × 2 = 1.4TB |
| JVM堆内存 | 分片数 × 1GB | 5分片 → 5GB堆 |
| 数据节点数 | 总存储 / 单节点存储 | 1.4TB / 2TB = 1节点(最少3) |

---

## 十二、运维SOP

```bash
#!/bin/bash
# elk_daily_check.sh - ELK日常巡检

echo "========== ELK日常巡检 =========="

# 1. ES集群状态
curl -s 'http://es-master:9200/_cluster/health?pretty' | grep -E "status|number_of_nodes|unassigned_shards"

# 2. 索引统计
curl -

... [OUTPUT TRUNCATED - 545 chars omitted out of 50545 total] ...

e: KAFKA_HEAP_OPTS
              value: "-Xmx4g -Xms4g"
          resources:
            requests:
              cpu: "2"
              memory: 6Gi
            limits:
              cpu: "4"
              memory: 8Gi
          volumeMounts:
            - name: data
              mountPath: /bitnami/kafka
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: local-ssd
        resources:
          requests:
            storage: 500Gi
```

### 13.3 Topic配置

```bash
# 创建日志Topic
kubectl exec -it kafka-0 -n logging -- \
  kafka-topics.sh --bootstrap-server localhost:9092 \
  --create \
  --topic elk-logs \
  --partitions 12 \
  --replication-factor 3 \
  --config retention.ms=604800000  # 7天 \
  --config retention.bytes=107374182400 \
  --config min.insync.replicas=2 \
  --config compression.type=lz4 \
  --config cleanup.policy=delete

# 创建审计日志Topic (更长保留)
kubectl exec -it kafka-0 -n logging -- \
  kafka-topics.sh --bootstrap-server localhost:9092 \
  --create \
  --topic elk-audit-logs \
  --partitions 6 \
  --replication-factor 3 \
  --config retention.ms=2592000000 \
  --config min.insync.replicas=2

# 查看Topic详情
kubectl exec -it kafka-0 -n logging -- \
  kafka-topics.sh --bootstrap-server localhost:9092 \
  --describe elk-logs

# 查看消费者组
kubectl exec -it kafka-0 -n logging -- \
  kafka-consumer-groups.sh --bootstrap-server localhost:9092  # [已修复] Kafka端口是9092不是9200 \
  --group logstash-consumer \
  --describe
```

### 13.4 Filebeat输出到Kafka

```yaml
# filebeat-kafka-output.yaml
filebeat.yml:
  output.kafka:
    hosts: ["kafka-0.kafka:9092", "kafka-1.kafka:9092", "kafka-2.kafka:9092"]
    topic: "elk-logs"
    partition.round_robin:
      reachable_only: true
    required_acks: 1
    compression: lz4
    max_message_bytes: 1000000
    worker: 4

  # 背压处理
  queue.mem:
    events: 8192
    flush.min_events: 1024
    flush.timeout: 3s
```

### 13.5 Logstash消费Kafka

```ruby
# logstash-kafka.conf
input {
  kafka {
    bootstrap_servers => "kafka-0.kafka:9092,kafka-1.kafka:9092,kafka-2.kafka:9092"
    topics => ["elk-logs"]
    group_id => "logstash-consumer"
    consumer_threads => 4
    decorate_events => true
    codec => "json"
    auto_offset_reset => "latest"
  }
}

filter {
  ruby {
    code => "event.set('logstash_received_at', Time.now.utc.iso8601(3))"
  }

  if [message] =~ /^\{/ {
    json {
      source => "message"
      target => "parsed"
      tag_on_failure => ["_json_parse_failure"]
    }
  }

  mutate {
    rename => { "kubernetes" => "k8s" }
    add_field => { "pipeline_version" => "v2.1" }
    remove_field => ["host"]
  }
}

output {
  elasticsearch {
    hosts => ["https://es-data-hot-0:9200", "https://es-data-hot-1:9200"]
    index => "enterprise-logs-%{+YYYY.MM.dd}"
    user => "elastic"
    password => "${ELASTIC_PASSWORD}"
    ssl_certificate_verification => true
    workers => 4
    batch_size => 5000
    idle_flush_time => 5
    manage_template => false
  }

  if "_json_parse_failure" in [tags] {
    file {
      path => "/var/log/logstash/parse_errors-%{+YYYY.MM.dd}.log"
      codec => line { format => "%{message}" }
    }
  }
}
```

---

## 十四、更多真实故障案例

### 案例4: JVM GC停顿导致查询超时

**故障现象**: ES集群周期性出现查询超时，Kibana仪表板无法加载，持续10-30秒

**根因分析**:
```bash
# 查看GC日志
grep -i "gc" /var/log/elasticsearch/gc.log | tail -50

# 输出显示:
# [2024-03-15T10:30:15.123+0800] GC(1234) Pause Full (Allocation Failure)
# [2024-03-15T10:30:15.123+0800] GC(1234)   Pause: 28456ms
# [2024-03-15T10:30:15.123+0800] GC(1234)   Workers: 8
```

**处理步骤**:
```bash
# 1. 检查当前堆内存使用
curl -s 'http://es-data-hot-0:9200/_nodes/stats/jvm' | jq '.nodes[] | {
  name: .name,
  heap_used: (.jvm.mem.heap_used_in_bytes / 1073741824 * 100 | round / 100),
  heap_max: (.jvm.mem.heap_max_in_bytes / 1073741824 * 100 | round / 100),
  gc_old_count: .jvm.gc.collectors.old.collection_count,
  gc_old_time: .jvm.gc.collectors.old.collection_time_in_millis
}'

# 2. 检查索引数量(分片过多导致内存压力)
curl -s 'http://es-data-hot-0:9200/_cat/indices?v' | wc -l

# 3. 临时调整(紧急)
curl -X PUT 'http://es-data-hot-0:9200/_cluster/settings' -H 'Content-Type: application/json' -d '{
  "persistent": { "cluster.max_shards_per_node": 500 }
}'

# 4. 长期优化 - 增大堆内存(不超过32GB)
# 在jvm.options中修改:
# -Xms24g
# -Xmx24g
```

**预防措施**: 设置堆内存监控告警，当使用率 > 75%时触发扩容

### 案例5: 分片不均衡导致热点节点

**故障现象**: 部分数据节点磁盘使用率达90%，其他节点仅30%

**根因分析**:
```bash
# 查看各节点磁盘使用
curl -s 'http://es-master:9200/_cat/allocation?v'

# Node                Shards   Disk.indices   Disk.used   Disk.avail   Disk.total   Disk.percent
# es-data-hot-0       180      1.2tb          1.3tb       670gb        2.0tb        66
# es-data-hot-1       45       300gb          350gb       1.6tb        2.0tb        18
# es-data-hot-2       15       50gb           80gb        1.9tb        2.0tb        4
```

**处理步骤**:
```bash
# 1. 重新均衡分片
curl -X POST 'http://es-master:9200/_cluster/reroute' -H 'Content-Type: application/json' -d '{
  "commands": [
    {
      "move": {
        "index": "enterprise-logs-2024.03.15",
        "shard": 0,
        "from_node": "es-data-hot-0",
        "to_node": "es-data-hot-2"
      }
    }
  ]
}'

# 2. 设置磁盘水位线告警
curl -X PUT 'http://es-master:9200/_cluster/settings' -H 'Content-Type: application/json' -d '{
  "persistent": {
    "cluster.routing.allocation.disk.watermark.low": "80%",
    "cluster.routing.allocation.disk.watermark.high": "85%",
    "cluster.routing.allocation.disk.watermark.flood_stage": "90%"
  }
}'

# 3. 启用自动分片均衡
curl -X PUT 'http://es-master:9200/_cluster/settings' -H 'Content-Type: application/json' -d '{
  "persistent": {
    "cluster.routing.rebalance.enable": "all",
    "cluster.routing.allocation.balance.shard": 0.45,
    "cluster.routing.allocation.balance.index": 0.55
  }
}'
```

### 案例6: 索引模板冲突导致字段类型错误

**故障现象**: 新创建的索引中，status_code字段被映射为text而非integer，导致聚合失败

**根因分析**:
```bash
# 查看当前索引模板
curl -s 'http://es-master:9200/_index_template?pretty' | jq '.index_templates[] | select(.name | startswith("enterprise"))'

# 发现存在多个模板，优先级高的模板覆盖了字段类型
# 旧模板: PUT _template/logs-template (priority=0)
# 新模板: PUT _index_template/enterprise-logs (priority=200)
```

**处理步骤**:
```bash
# 1. 删除冲突的旧模板
curl -X DELETE 'http://es-master:9200/_template/logs-template'

# 2. 更新索引模板(使用严格模式)
curl -X PUT 'http://es-master:9200/_index_template/enterprise-logs' -H 'Content-Type: application/json' -d '{
  "index_patterns": ["enterprise-logs-*"],
  "template": {
    "mappings": {
      "dynamic": "strict",
      "properties": {
        "@timestamp": { "type": "date" },
        "status_code": { "type": "integer" },
        "response_time": { "type": "float" },
        "message": { "type": "text" }
      }
    }
  },
  "priority": 300
}'

# 3. 重建受影响的索引
curl -X PUT 'http://es-master:9200/enterprise-logs-2024.03.15-fix' -H 'Content-Type: application/json' -d '{
  "settings": { "number_of_shards": 3, "number_of_replicas": 1 },
  "mappings": {
    "dynamic": "strict",
    "properties": {
      "status_code": { "type": "integer" },
      "message": { "type": "text" }
    }
  }
}'

# 使用reindex迁移数据
curl -X POST 'http://es-master:9200/_reindex' -H 'Content-Type: application/json' -d '{
  "source": { "index": "enterprise-logs-2024.03.15" },
  "dest": { "index": "enterprise-logs-2024.03.15-fix" }
}'
```

### 案例7: Logstash队列阻塞导致数据堆积

**故障现象**: Kafka中elk-logs topic的消费者lag持续增长，从0增长到100万条

**根因分析**:
```bash
# 查看消费者组状态
kafka-consumer-groups.sh --bootstrap-server kafka-0:9092 \
  --group logstash-consumer --describe

# GROUP              TOPIC           PARTITION  CURRENT-OFFSET  LOG-END-OFFSET  LAG
# logstash-consumer  elk-logs        0          1234567         1235678         1111
# ... (所有分区lag都在增长)

# 查看Logstash pipeline状态
curl -s 'http://logstash:9600/_node/stats/pipelines/main?pretty' | jq '.pipelines.main.events'
# {
#   "in": 5000000,
#   "filtered": 4800000,
#   "out": 2000000,  # 输出远小于输入，说明output阻塞
# }
```

**处理步骤**:
```bash
# 1. 临时增加Logstash worker
# pipeline.workers: 8
# pipeline.batch.size: 5000

# 2. 优化ES output配置
# elasticsearch {
#   workers => 4
#   batch_size => 5000
#   idle_flush_time => 5
#   retry_max_interval => 30
# }

# 3. 监控恢复
while true; do
  kafka-consumer-groups.sh --bootstrap-server kafka-0:9092 \
    --group logstash-consumer --describe | \
    awk 'NR>1{sum+=$5}END{print "Total lag: "sum}'
  sleep 10
done
```

### 案例8: CCR(跨集群复制)同步延迟

**故障现象**: 灾备集群的索引数据比主集群延迟30分钟以上

**根因分析**:
```bash
# 查看CCR状态
curl -s 'http://es-secondary:9200/_ccr/stats?pretty' | jq '.follow_stats[]'

# outstanding_write_requests=50 表示写入队列堆积
```

**处理步骤**:
```bash
# 1. 检查网络延迟
ping -c 10 es-secondary.internal
# 发现网络延迟从1ms增加到50ms

# 2. 检查灾备集群磁盘IO
iostat -x 1 5
# 磁盘利用率 95%，IO等待严重

# 3. 临时方案: 增加follower shard
curl -X POST 'http://es-secondary:9200/_ccr/pause_follow/enterprise-logs-2024.03.15'

# 4. 长期方案:
# - 将灾备集群升级到与主集群相同的磁盘规格
# - 使用专用网络链路
# - 设置CCR同步监控告警
```

---

## 十五、性能调优详细参数

### 15.1 JVM堆内存计算公式

```
最佳堆内存 = min(物理内存 × 0.5, 31.5GB)
ES_JAVA_OPTS = "-Xms{heap}g -Xmx{heap}g"

示例计算:
- 64GB内存服务器 → heap = min(64×0.5, 31.5) = 31.5GB → -Xms31g -Xmx31g
- 32GB内存服务器 → heap = min(32×0.5, 31.5) = 16GB → -Xms16g -Xmx16g
- 16GB内存服务器 → heap = min(16×0.5, 31.5) = 8GB → -Xms8g -Xmx8g

G1GC参数推荐:
| 堆大小 | Region大小 | IHOP | MaxGCPause |
|--------|-----------|------|------------|
| < 8GB  | 2MB       | 40%  | 200ms      |
| 8-16GB | 4MB       | 35%  | 200ms      |
| 16-32GB| 8MB       | 30%  | 200ms      |
```

### 15.2 操作系统调优

```bash
# /etc/sysctl.conf
# 内存管理
vm.max_map_count=262144
vm.swappiness=1
vm.overcommit_memory=1
vm.dirty_ratio=15
vm.dirty_background_ratio=5

# 网络参数
net.core.somaxconn=65535
net.ipv4.tcp_max_syn_backlog=65535
net.core.netdev_max_backlog=65535
net.ipv4.tcp_tw_reuse=1

# 文件系统
fs.file-max=2097152
fs.inotify.max_user_watches=524288

# 应用配置
sysctl -p

# /etc/security/limits.conf
* soft nofile 131072
* hard nofile 131072
* soft nproc 65536
* hard nproc 65536
* soft memlock unlimited
* hard memlock unlimited

# 禁用swap
swapoff -a
```

### 15.3 索引层优化参数

```json
// PUT _cluster/settings
{
  "persistent": {
    "cluster.routing.allocation.require.node_role": "data_hot",
    "cluster.routing.allocation.disk.watermark.low": "80%",
    "cluster.routing.allocation.disk.watermark.high": "85%",
    "indices.memory.index_buffer_size": "15%",
    "indices.recovery.max_bytes_per_sec": "250mb",
    "search.max_concurrent_shard_requests": 5,
    "search.max_shard_requests_per_node": 5
  }
}

// PUT _index_template/enterprise-logs
{
  "index_patterns": ["enterprise-logs-*"],
  "template": {
    "settings": {
      "number_of_shards": 3,
      "number_of_replicas": 1,
      "refresh_interval": "5s",
      "translog.durability": "async",
      "translog.flush_threshold_size": "512mb",
      "translog.sync_interval": "30s",
      "codec": "best_compression",
      "routing.allocation.require.node_role": "data_hot"
    }
  }
}
```

### 15.4 查询优化详细配置

```bash
# Elasticsearch查询优化示例:
# 糟糕的查询:
GET /logs-*/_search
{
  "query": {
    "query_string": {
      "query": "*error* OR *fail*"
    }
  },
  "size": 10000
}

# 优化后的查询:
GET /logs-*/_search
{
  "query": {
    "bool": {
      "filter": [
        { "term": { "level": "ERROR" } },
        { "range": { "@timestamp": { "gte": "now-1h" } } }
      ]
    }
  },
  "_source": ["@timestamp", "message", "service"],
  "size": 100,
  "terminate_after": 1000
}

# 使用滚动搜索代替深分页
GET /logs-*/_search
{
  "size": 100,
  "search_after": ["2024-03-15T10:30:00.000Z", "abc123"],
  "sort": [
    { "@timestamp": "desc" },
    { "_doc": "desc" }
  ]
}
```

### 15.5 Filebeat优化参数

```yaml
# filebeat.yml 优化配置
filebeat.inputs:
  - type: container
    paths:
      - /var/log/containers/*.log
    harvester_buffer_size: 65536
    max_bytes: 10485760
    close_timeout: 5m
    clean_inactive: 72h
    clean_removed: true
    scan_frequency: 10s

processors:
  - add_kubernetes_metadata:
      host: ${NODE_NAME}
  - decode_json_fields:
      fields: ["message"]
      target: ""
      overwrite_keys: true
  - drop_event:
      when:
        regexp:
          message: "^$"

queue.mem:
  events: 16384
  flush.min_events: 2048
  flush.timeout: 5s

output.elasticsearch:
  bulk_max_size: 10000
  worker: 4
  loadbalance: true
  compression_level: 3
  slow_log: 30s

monitoring.enabled: true
monitoring.collection_interval: 30s
monitoring.elasticsearch.hosts: ["https://es-master-0:9200"]
```

---

## 十六、灾备方案

### 16.1 灾备架构设计

```
                    ┌─────────────────────────────┐
                    │      主集群 (北京)           │
                    │  ES Master x 3              │
                    │  ES Data-Hot x 3            │
                    │  ES Data-Warm x 2           │
                    │  Logstash x 3               │
                    │  Filebeat (DaemonSet)       │
                    └──────────┬──────────────────┘
                               │
                          CCR复制
                               │
                    ┌──────────▼──────────────────┐
                    │      灾备集群 (上海)         │
                    │  ES Master x 3              │
                    │  ES Data-Hot x 3            │
                    │  ES Data-Warm x 2           │
                    │  (只读模式)                  │
                    └──────────┬──────────────────┘
                               │
                    ┌──────────▼──────────────────┐
                    │      Snapshot存储 (S3/OSS)   │
                    │  每日全量快照                 │
                    │  保留30天                    │
                    └─────────────────────────────┘
```

### 16.2 Snapshot备份配置

```bash
# 1. 注册备份仓库
curl -X PUT 'http://es-master:9200/_snapshot/s3_backup' -H 'Content-Type: application/json' -d '{
  "type": "s3",
  "settings": {
    "bucket": "enterprise-es-snapshots",
    "region": "cn-north-1",
    "base_path": "enterprise-logs",
    "compress": true,
    "server_side_encryption": true,
    "max_snapshot_bytes_per_sec": "100mb",
    "max_restore_bytes_per_sec": "200mb"
  }
}'

# 2. 验证仓库
curl -X POST 'http://es-master:9200/_snapshot/s3_backup/_verify'

# 3. 创建每日备份脚本
cat > /usr/local/bin/es_snapshot_backup.sh << 'SNAPSHOT_EOF'
#!/bin/bash
SNAPSHOT_NAME="daily-$(date +%Y%m%d-%H%M%S)"
ES_HOST="http://es-master:9200"
REPO="s3_backup"

echo "Creating snapshot: ${SNAPSHOT_NAME}"
curl -X PUT "${ES_HOST}/_snapshot/${REPO}/${SNAPSHOT_NAME}?wait_for_completion=true" \
  -H 'Content-Type: application/json' -d '{
  "indices": "enterprise-logs-*",
  "ignore_unavailable": true,
  "include_global_state": false,
  "metadata": { "created_by": "daily-backup-script" }
}'

curl -s "${ES_HOST}/_snapshot/${REPO}/${SNAPSHOT_NAME}" | jq '.snapshots[].state'

CUTOFF_DATE=$(date -d "30 days ago" +%Y%m%d)
curl -s "${ES_HOST}/_snapshot/${REPO}/_all" | \
  jq -r '.snapshots[] | select(.snapshot < "daily-'${CUTOFF_DATE}'") | .snapshot' | \
  while read snap; do
    echo "Deleting old snapshot: ${snap}"
    curl -X DELETE "${ES_HOST}/_snapshot/${REPO}/${snap}"
  done
SNAPSHOT_EOF
chmod +x /usr/local/bin/es_snapshot_backup.sh

# 4. 添加crontab任务
# 0 2 * * * /usr/local/bin/es_snapshot_backup.sh >> /var/log/es_snapshot.log 2>&1
```

### 16.3 故障切换SOP

```
# 主集群故障切换流程 (RTO < 30分钟)

## 阶段1: 确认故障 (5分钟)
1. 检查主集群状态
   curl -s 'http://es-master:9200/_cluster/health?pretty'

2. 通知相关人员

## 阶段2: 启用灾备集群 (10分钟)
1. 将灾备集群设为可写
   curl -X PUT 'http://es-secondary:9200/_cluster/settings' -H 'Content-Type: application/json' -d '{
     "persistent": { "cluster.blocks.read_only_allow_delete": false }
   }'

2. 更新DNS指向灾备集群

3. 更新Filebeat配置指向灾备集群
   kubectl -n logging rollout restart daemonset filebeat

4. 更新Logstash输出到灾备集群
   kubectl -n logging rollout restart deployment logstash

## 阶段3: 验证切换 (5分钟)
1. 确认Kibana可访问
2. 验证日志采集正常
3. 验证查询功能正常

## 阶段4: 事后处理
1. 通知切换完成
2. 监控灾备集群性能
3. 等待主集群恢复
4. 主集群恢复后，将数据同步回主集群
5. 执行回切操作
```

---

## 十七、成本估算

### 17.1 自建方案 vs 云服务对比

| 资源类型 | 自建方案 | 云服务(阿里云ES) | 对比 |
|---------|---------|-----------------|------|
| ES Master x 3 | 8C/32G/200G SSD x 3 | 无需管理 | 云服务省运维 |
| ES Data-Hot x 3 | 16C/64G/2T NVMe x 3 | 3节点高配 | 云服务更贵 |
| ES Data-Warm x 2 | 8C/32G/4T HDD x 2 | 无需管理 | 云服务省运维 |
| ES Data-Cold x 1 | 4C/16G/10T HDD x 1 | 无需管理 | 云服务省运维 |
| Kibana x 2 | 4C/8G/50G x 2 | 包含 | - |
| Logstash x 3 | 8C/16G/100G x 3 | 无需管理 | 云服务省运维 |
| Kafka x 3 | 8C/16G/500G x 3 | 无需管理 | 云服务省运维 |
| 运维人力 | 0.5人/月 | 0.1人/月 | - |

### 17.2 三年TCO计算

```
自建方案 (3年):
  硬件折旧 (按3年直线折旧):
    ES Master x 3:    ¥6,000/月 × 36 = ¥216,000
    ES Data-Hot x 3:  ¥12,000/月 × 36 = ¥432,000
    ES Data-Warm x 2: ¥4,000/月 × 36 = ¥144,000
    ES Data-Cold x 1: ¥2,500/月 × 36 = ¥90,000
    Kibana x 2:       ¥800/月 × 36 = ¥28,800
    Logstash x 3:     ¥3,000/月 × 36 = ¥108,000
    Kafka x 3:        ¥3,000/月 × 36 = ¥108,000

  网络带宽:
    100Mbps专线: ¥5,000/月 × 36 = ¥180,000

  运维人力:
    0.5人 × ¥15,000/月 × 36 = ¥270,000

  电力/IDC:
    ¥2,000/月 × 36 = ¥72,000

  总计: ¥1,548,800 (约155万/3年)

云服务方案 (3年):
  阿里云ES集群 (3节点高配+2节点中配):
    高配节点 x 3: ¥8,000/月 × 3 × 36 = ¥864,000
    中配节点 x 2: ¥4,000/月 × 2 × 36 = ¥288,000
    低配节点 x 1: ¥2,000/月 × 1 × 36 = ¥72,000

  阿里云Kafka:
    ¥3,000/月 × 36 = ¥108,000

  网络带宽:
    100Mbps: ¥3,000/月 × 36 = ¥108,000

  运维人力:
    0.1人 × ¥15,000/月 × 36 = ¥54,000

  总计: ¥1,494,000 (约149万/3年)

结论: 云服务略便宜，但自建方案在数据量大时更划算
      建议: 核心日志自建，非核心日志用云服务
```

---

## 十八、监控告警配置

### 18.1 Prometheus指标采集

```yaml
# elasticsearch-exporter-deployment.yaml
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: elasticsearch-exporter
  namespace: monitoring
spec:
  replicas: 1
  selector:
    matchLabels:
      app: elasticsearch-exporter
  template:
    metadata:
      labels:
        app: elasticsearch-exporter
    spec:
      containers:
        - name: elasticsearch-exporter
          image: prometheuscommunity/elasticsearch-exporter:v1.7.0
          args:
            - "--es.uri=https://elastic:${ELASTIC_PASSWORD}@es-master-0:9200"
            - "--es.all"
            - "--es.indices"
            - "--es.indices_settings"
            - "--es.indices_mappings"
            - "--es.shards"
            - "--es.snapshots"
            - "--es.cluster_settings"
            - "--web.listen-address=:9114"
          ports:
            - containerPort: 9114
              name: metrics
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 200m
              memory: 256Mi
---
apiVersion: v1
kind: Service
metadata:
  name: elasticsearch-exporter
  namespace: monitoring
spec:
  selector:
    app: elasticsearch-exporter
  ports:
    - port: 9114
      name: metrics
```

### 18.2 告警规则

```yaml
# elasticsearch-alerts.yaml
groups:
  - name: elasticsearch-alerts
    rules:
      - alert: ElasticsearchClusterRed
        expr: elasticsearch_cluster_health_status{color="red"} == 1
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "ES集群状态RED"
          description: "Elasticsearch集群 {{ $labels.cluster }} 状态为RED"

      - alert: ElasticsearchClusterYellow
        expr: elasticsearch_cluster_health_status{color="yellow"} == 1
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "ES集群状态YELLOW"
          description: "Elasticsearch集群 {{ $labels.cluster }} 状态为YELLOW"

      - alert: ElasticsearchNodeDown
        expr: up{job="elasticsearch"} == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "ES节点离线"
          description: "节点 {{ $labels.instance }} 已离线超过1分钟"

      - alert: ElasticsearchJVMHeapHigh
        expr: elasticsearch_jvm_memory_used_bytes{area="heap"} / elasticsearch_jvm_memory_max_bytes{area="heap"} > 0.80
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "ES JVM堆内存使用率 > 80%"
          description: "节点 {{ $labels.name }} JVM堆内存使用率 {{ $value | humanizePercentage }}"

      - alert: ElasticsearchDiskSpaceLow
        expr: elasticsearch_filesystem_data_available_bytes / elasticsearch_filesystem_data_size_bytes < 0.15
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "ES磁盘空间不足15%"
          description: "节点 {{ $labels.name }} 磁盘剩余 {{ $value | humanizePercentage }}"

      - alert: ElasticsearchDiskSpaceCritical
        expr: elasticsearch_filesystem_data_available_bytes / elasticsearch_filesystem_data_size_bytes < 0.05
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "ES磁盘空间严重不足"
          description: "节点 {{ $labels.name }} 磁盘剩余 {{ $value | humanizePercentage }}"

      - alert: ElasticsearchUnassignedShards
        expr: elasticsearch_cluster_health_unassigned_shards > 0
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "存在未分配分片"
          description: "集群 {{ $labels.cluster }} 有 {{ $value }} 个未分配分片"

      - alert: ElasticsearchIndexingLatencyHigh
        expr: rate(elasticsearch_indices_indexing_index_time_seconds_total[5m]) > 0.5
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "ES索引延迟过高"
          description: "节点 {{ $labels.name }} 索引延迟 {{ $value }}s"

      - alert: ElasticsearchSearchLatencyHigh
        expr: rate(elasticsearch_indices_search_query_time_seconds_total[5m]) > 1
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "ES搜索延迟过高"
          description: "节点 {{ $labels.name }} 搜索延迟 {{ $value }}s"

      - alert: FilebeatNotRunning
        expr: kube_pod_status_phase{namespace="logging", pod=~"filebeat.*", phase="Running"} == 0
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "Filebeat未运行"
          description: "Filebeat Pod {{ $labels.pod }} 未处于Running状态"

      - alert: LogstashNotRunning
        expr: kube_pod_status_phase{namespace="logging", pod=~"logstash.*", phase="Running"} == 0
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "Logstash未运行"
          description: "Logstash Pod {{ $labels.pod }} 未处于Running状态"
```

### 18.3 Grafana Dashboard

```json
{
  "dashboard": {
    "title": "Elasticsearch集群监控",
    "panels": [
      {
        "title": "集群状态",
        "type": "stat",
        "targets": [{
          "expr": "elasticsearch_cluster_health_status{color=\"green\"}"
        }]
      },
      {
        "title": "JVM堆内存使用率",
        "type": "timeseries",
        "targets": [{
          "expr": "elasticsearch_jvm_memory_used_bytes{area=\"heap\"} / elasticsearch_jvm_memory_max_bytes{area=\"heap\"}"
        }]
      },
      {
        "title": "索引速率",
        "type": "timeseries",
        "targets": [{
          "expr": "rate(elasticsearch_indices_indexing_index_total[5m])"
        }]
      },
      {
        "title": "搜索速率",
        "type": "timeseries",
        "targets": [{
          "expr": "rate(elasticsearch_indices_search_query_total[5m])"
        }]
      },
      {
        "title": "磁盘使用率",
        "type": "timeseries",
        "targets": [{
          "expr": "elasticsearch_filesystem_data_used_bytes / elasticsearch_filesystem_data_size_bytes"
        }]
      },
      {
        "title": "未分配分片",
        "type": "stat",
        "targets": [{
          "expr": "elasticsearch_cluster_health_unassigned_shards"
        }]
      }
    ]
  }
}
```

---

## 十九、安全加固

### 19.1 TLS证书配置

```bash
# 1. 生成CA证书
openssl genrsa -out ca.key 4096
openssl req -new -x509 -days 3650 -key ca.key -out ca.crt -subj "/CN=Enterprise-ES-CA"

# 2. 生成HTTP证书
openssl genrsa -out http.key 2048
openssl req -new -key http.key -out http.csr -subj "/CN=es-master-0.elasticsearch.svc"
openssl x509 -req -days 3650 -in http.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out http.crt

# 3. 生成Transport证书
openssl genrsa -out transport.key 2048
openssl req -new -key transport.key -out transport.csr -subj "/CN=transport"
openssl x509 -req -days 3650 -in transport.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out transport.crt

# 4. 转换为PKCS12
openssl pkcs12 -export -in http.crt -inkey http.key -out http.p12 -password pass:changeit
openssl pkcs12 -export -in transport.crt -inkey transport.key -out transport.p12 -password pass:changeit

# 5. 创建K8s Secret
kubectl create secret generic es-certs \
  --from-file=http.p12=http.p12 \
  --from-file=transport.p12=transport.p12 \
  --from-file=ca.crt=ca.crt \
  -n logging
```

### 19.2 用户权限配置

```bash
# 创建只读用户
curl -X POST 'http://es-master:9200/_security/user/kibana_readonly' -H 'Content-Type: application/json' -d '{
  "password": "${READONLY_PASSWORD}",
  "roles": ["kibana_readonly"],
  "full_name": "Kibana Readonly User"
}'

# 创建自定义角色
curl -X PUT 'http://es-master:9200/_security/role/kibana_readonly' -H 'Content-Type: application/json' -d '{
  "cluster": ["monitor"],
  "indices": [
    {
      "names": ["enterprise-logs-*"],
      "privileges": ["read", "view_index_metadata"],
      "field_security": {
        "grant": ["@timestamp", "message", "level", "service", "pod"]
      }
    }
  ]
}'

# 创建写入用户(用于Logstash)
curl -X POST 'http://es-master:9200/_security/user/logstash_writer' -H 'Content-Type: application/json' -d '{
  "password": "${LOGSTASH_PASSWORD}",
  "roles": ["logstash_writer"],
  "full_name": "Logstash Writer User"
}'

# 创建写入角色
curl -X PUT 'http://es-master:9200/_security/role/logstash_writer' -H 'Content-Type: application/json' -d '{
  "cluster": ["manage_index_templates", "monitor", "manage_ilm"],
  "indices": [
    {
      "names": ["enterprise-logs-*"],
      "privileges": ["write", "create_index", "manage"]
    }
  ]
}'

# 创建管理员用户
curl -X POST 'http://es-master:9200/_security/user/es_admin' -H 'Content-Type: application/json' -d '{
  "password": "${ADMIN_PASSWORD}",
  "roles": ["superuser"],
  "full_name": "ES Admin User"
}'
```

### 19.3 审计日志配置

```json
// PUT _cluster/settings
{
  "persistent": {
    "xpack.security.audit.enabled": true,
    "xpack.security.audit.logfile.events.include": [
      "access_denied",
      "access_granted",
      "anonymous_access_denied",
      "authentication_failed",
      "connection_denied",
      "run_as_denied",
      "run_as_granted"
    ],
    "xpack.security.audit.logfile.events.exclude": [
      "_cluster/health",
      "_cat/"
    ],
    "xpack.security.audit.logfile.emit_request_body": true
  }
}

// 审计日志输出位置
// 默认: /var/log/elasticsearch/audit.json
// 建议: 使用Filebeat收集审计日志到ES
```

---

## 二十、版本升级SOP

### 20.1 升级前准备

```bash
# 1. 检查当前版本
curl -s 'http://es-master:9200' | jq '.version'

# 2. 查看兼容性矩阵
# https://www.elastic.co/support/matrix#matrix_compatibility

# 3. 备份当前集群配置
curl -s 'http://es-master:9200/_cluster/settings?pretty' > cluster_settings_backup.json
curl -s 'http://es-master:9200/_template?pretty' > templates_backup.json
curl -s 'http://es-master:9200/_ilm/policy?pretty' > ilm_policies_backup.json

# 4. 创建Snapshot备份
/usr/local/bin/es_snapshot_backup.sh

# 5. 检查索引兼容性
curl -s 'http://es-master:9200/_cat/indices?v&h=index,creation_date.version'

# 6. 禁用分片分配(减少升级时的IO)
curl -X PUT 'http://es-master:9200/_cluster/settings' -H 'Content-Type: application/json' -d '{
  "persistent": {
    "cluster.routing.allocation.enable": "primaries"
  }
}'
```

### 20.2 逐步升级流程

```bash
# 升级顺序: Master → Data-Warm → Data-Cold → Data-Hot → Kibana → Logstash

# 1. 升级Master节点(先升级1个)
kubectl -n logging set image statefulset/es-master \
  elasticsearch=elasticsearch:8.12.0

# 等待节点加入集群
curl -s 'http://es-master:9200/_cat/nodes?v' | grep master

# 验证集群状态
curl -s 'http://es-master:9200/_cluster/health?pretty'

# 2. 重复步骤1升级其他Master节点

# 3. 升级Data-Warm节点
kubectl -n logging set image statefulset/es-data-warm \
  elasticsearch=elasticsearch:8.12.0

# 4. 升级Data-Cold节点
kubectl -n logging set image statefulset/es-data-cold \
  elasticsearch=elasticsearch:8.12.0

# 5. 升级Data-Hot节点(最后升级，因为影响最大)
kubectl -n logging set image statefulset/es-data-hot \
  elasticsearch=elasticsearch:8.12.0 --index=0

# 等待分片恢复
curl -s 'http://es-master:9200/_cat/recovery?v&active_only=true' | wc -l

# 6. 升级Kibana
kubectl -n logging set image deployment/kibana \
  kibana=kibana:8.12.0

# 等待Kibana启动
curl -s 'http://kibana:5601/api/status' | jq '.status.overall'

# 7. 升级Logstash
kubectl -n logging set image deployment/logstash \
  logstash=logstash:8.12.0

# 8. 升级Filebeat
kubectl -n logging set image daemonset/filebeat \
  filebeat=elastic/filebeat:8.12.0
```

### 20.3 升级后验证

```bash
# 1. 验证集群健康状态
curl -s 'http://es-master:9200/_cluster/health?pretty'
# 确认: status=green, number_of_nodes=预期值

# 2. 验证所有节点版本
curl -s 'http://es-master:9200/_cat/nodes?v&h=name,version'
# 确认所有节点版本一致

# 3. 验证索引正常
curl -s 'http://es-master:9200/_cat/indices?v' | head -20

# 4. 验证ILM策略正常
curl -s 'http://es-master:9200/_ilm/explain?pretty' | jq '.indices[].step_info'

# 5. 重新启用分片分配
curl -X PUT 'http://es-master:9200/_cluster/settings' -H 'Content-Type: application/json' -d '{
  "persistent": {
    "cluster.routing.allocation.enable": "all"
  }
}'

# 6. 更新监控配置
```

### 20.4 回滚方案

```bash
# 如果升级失败，执行以下回滚步骤:

# 1. 停止新版本节点
kubectl -n logging delete pod es-master-0

# 2. 恢复旧版本镜像
kubectl -n logging set image statefulset/es-master \
  elasticsearch=elasticsearch:8.11.3

# 3. 恢复集群配置
curl -X PUT 'http://es-master:9200/_cluster/settings' -H 'Content-Type: application/json' \
  -d @cluster_settings_backup.json

# 4. 恢复索引模板
curl -X PUT 'http://es-master:9200/_template/logs-template' -H 'Content-Type: application/json' \
  -d @templates_backup.json

# 5. 验证集群恢复
curl -s 'http://es-master:9200/_cluster/health?pretty'
```

---



## 踩坑记录

### Q1: ES集群状态RED
**原因**: 节点宕机导致主分片丢失
**解决**: 重启宕机节点或使用allocate_stale_primary强制分配

### Q2: Filebeat日志丢失
**原因**: 背压(backpressure)导致丢弃日志
**解决**: 增大queue.mem.events和bulk_max_size

### Q3: Kibana Discover加载缓慢
**原因**: 索引数据量太大+查询范围过广
**解决**: 缩短默认时间范围，配置ILM生命周期

### Q4: Logstash pipeline积压
**原因**: ES写入速度跟不上Logstash输出速度
**解决**: 增加Logstash worker数量，减小batch size

### Q5: ILM rollover不生效
**原因**: Filebeat index名称与ILM rollover_alias不匹配
**解决**: 确保Filebeat输出使用alias而非直接写入索引名

> 本项目基于官方文档、技术博客和社区实践深度学习编写