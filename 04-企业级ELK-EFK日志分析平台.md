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
   119|            - containerPort: 9200
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
   138|              memory: 20Gi
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
   151|              port: 9200
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
   252|          "freeze": {}
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
   331|            runAsUser: 0
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
   347|              mountPath: /var/lib/docker/containers
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
   366|            path: /var/lib/docker/containers
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
curl -s 'http://es-master:9200/_cat/indices?v&s=store.size:desc&h=index,health,pri,rep,docs.count,store.size' | head -20

# 3. 磁盘使用
curl -s 'http://es-master:9200/_cat/allocation?v' | head -10

# 4. 慢查询日志
curl -s 'http://es-master:9200/_nodes/stats/indices.search' | jq '.nodes[].indices.search.query_total'

# 5. Filebeat状态
kubectl -n logging get pods -l app=filebeat -o wide
```

---

> 本项目基于25个语雀知识库(2699篇,584万字)深度学习编写
