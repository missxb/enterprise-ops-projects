# 企业级ELK/EFK日志分析平台

> 完整实现企业级日志收集、存储、检索、可视化全链路
> 覆盖: Elasticsearch集群 + Filebeat + Kibana + ILM生命周期 + 安全加固

---

## 一、架构总览

```
应用Pod ──▶ Filebeat(DaemonSet) ──▶ Kafka(可选缓冲) ──▶ Logstash ──▶ Elasticsearch ──▶ Kibana
                                      │                                      │
                                      │              ┌────────────────────────┘
                                      │              ▼
                                      │    ILM生命周期管理
                                      │    热节点(SSD) → 温节点(HDD) → 冷节点(归档)
                                      │
                                      └──▶ 直连ES(轻量方案,跳过Logstash)
```

---

## 二、服务器规划

| 服务 | 数量 | 配置 | 用途 |
|------|------|------|------|
| Elasticsearch Master | 3 | 8C/32G/200G SSD | 集群管理+协调 |
| Elasticsearch Data-Hot | 3 | 16C/64G/2T NVMe | 热数据(7天) |
| Elasticsearch Data-Warm | 2 | 8C/32G/4T HDD | 温数据(30天) |
| Elasticsearch Data-Cold | 1 | 4C/16G/10T HDD | 冷数据(90天) |
| Kibana | 2 | 4C/8G/50G | 可视化 |
| Logstash | 3 | 8C/16G/100G | 日志转换 |
| Filebeat | DaemonSet | - | 日志采集 |

---

## 三、Elasticsearch集群部署

```yaml
# elasticsearch-statefulset.yaml
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: elasticsearch-config
  namespace: logging
data:
  elasticsearch.yml: |
    cluster.name: enterprise-logs
    node.name: ${NODE_NAME}
    node.roles: [master]
    path.data: /usr/share/elasticsearch/data
    path.logs: /usr/share/elasticsearch/logs
    network.host: 0.0.0.0
    discovery.seed_hosts:
      - es-master-0.es-master.logging.svc.cluster.local
      - es-master-1.es-master.logging.svc.cluster.local
      - es-master-2.es-master.logging.svc.cluster.local
    cluster.initial_master_nodes:
      - es-master-0
      - es-master-1
      - es-master-2
    xpack.security.enabled: true
    xpack.security.transport.ssl.enabled: true
    xpack.security.transport.ssl.verification_mode: certificate
    xpack.security.transport.ssl.keystore.path: /usr/share/elasticsearch/config/certs/transport.p12
    xpack.security.transport.ssl.truststore.path: /usr/share/elasticsearch/config/certs/transport.p12
    xpack.security.http.ssl.enabled: true
    xpack.security.http.ssl.keystore.path: /usr/share/elasticsearch/config/certs/http.p12

  jvm.options: |
    -Xms16g
    -Xmx16g
    -XX:+UseG1GC
    -XX:G1HeapRegionSize=4m
    -XX:InitiatingHeapOccupancyPercent=30
    -XX:G1ReservePercent=15
    -XX:MaxGCPauseMillis=200
    -Djava.io.tmpdir=/tmp
    -XX:+HeapDumpOnOutOfMemoryError
    -XX:HeapDumpPath=/tmp/heapdump.hprof

---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: es-master
  namespace: logging
spec:
  serviceName: es-master
  replicas: 3
  selector:
    matchLabels:
      app: elasticsearch
      role: master
  template:
    metadata:
      labels:
        app: elasticsearch
        role: master
    spec:
      initContainers:
        # 设置vm.max_map_count
        - name: sysctl
          image: busybox
          command: ['sysctl', '-w', 'vm.max_map_count=262144']
          securityContext:
            privileged: true
        # 设置文件描述符
        - name: ulimit
          image: busybox
          command: ['sh', '-c', 'ulimit -n 65536']
          securityContext:
            privileged: true
      containers:
        - name: elasticsearch
          image: elasticsearch:8.11.3
          ports:
            - containerPort: 9200
              name: http
            - containerPort: 9300
              name: transport
          env:
            - name: NODE_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
            - name: ES_JAVA_OPTS
              value: "-Xms16g -Xmx16g"
            - name: ELASTIC_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: elasticsearch-credentials
                  key: elastic
          resources:
            requests:
              cpu: "4"
              memory: 20Gi
            limits:
              cpu: "8"
              memory: 32Gi
          volumeMounts:
            - name: elasticsearch-data
              mountPath: /usr/share/elasticsearch/data
            - name: config
              mountPath: /usr/share/elasticsearch/config/elasticsearch.yml
              subPath: elasticsearch.yml
          readinessProbe:
            httpGet:
              path: /_cluster/health?local=true
              port: 9200
              scheme: https
            initialDelaySeconds: 30
            periodSeconds: 10
  
  volumeClaimTemplates:
    - metadata:
        name: elasticsearch-data
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: local-ssd
        resources:
          requests:
            storage: 200Gi

---
# Data Hot节点 (NVMe SSD)
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: es-data-hot
  namespace: logging
spec:
  serviceName: es-data-hot
  replicas: 3
  selector:
    matchLabels:
      app: elasticsearch
      role: data-hot
  template:
    spec:
      containers:
        - name: elasticsearch
          image: elasticsearch:8.11.3
          env:
            - name: NODE_ROLES
              value: "data_hot,ingest"
            - name: ES_JAVA_OPTS
              value: "-Xms28g -Xmx28g"
          resources:
            requests:
              cpu: "8"
              memory: 40Gi
            limits:
              cpu: "16"
              memory: 64Gi
  
  volumeClaimTemplates:
    - metadata:
        name: elasticsearch-data
      spec:
        storageClassName: local-nvme
        resources:
          requests:
            storage: 2Ti
```

---

## 四、ILM生命周期管理

```json
// PUT _ilm/policy/enterprise-logs-policy
{
  "policy": {
    "phases": {
      "hot": {
        "min_age": "0ms",
        "actions": {
          "rollover": {
            "max_primary_shard_size": "50gb",
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
          },
          "migrate": {
            "enabled": true
          }
        }
      },
      "cold": {
        "min_age": "30d",
        "actions": {
          "set_priority": {
            "priority": 0
          },
          "freeze": {}
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
}
```

```bash
# 创建Index Template
curl -X PUT "http://es-master-0:9200/_index_template/enterprise-logs" -H 'Content-Type: application/json' -d'
{
  "index_patterns": ["enterprise-logs-*"],
  "template": {
    "settings": {
      "number_of_shards": 3,
      "number_of_replicas": 1,
      "index.lifecycle.name": "enterprise-logs-policy",
      "index.lifecycle.rollover_alias": "enterprise-logs",
      "index.routing.allocation.require.node_role": "data_hot"
    },
    "mappings": {
      "properties": {
        "@timestamp": { "type": "date" },
        "message": { "type": "text" },
        "level": { "type": "keyword" },
        "service": { "type": "keyword" },
        "namespace": { "type": "keyword" },
        "pod": { "type": "keyword" },
        "container": { "type": "keyword" },
        "host": { "type": "keyword" },
        "trace_id": { "type": "keyword" },
        "method": { "type": "keyword" },
        "path": { "type": "keyword" },
        "status_code": { "type": "integer" },
        "response_time": { "type": "float" },
        "client_ip": { "type": "ip" },
        "user_agent": { "type": "text" }
      }
    }
  },
  "priority": 200
}'
```

---

## 五、Filebeat DaemonSet

```yaml
# filebeat-daemonset.yaml
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: filebeat
  namespace: logging
spec:
  selector:
    matchLabels:
      app: filebeat
  template:
    metadata:
      labels:
        app: filebeat
    spec:
      serviceAccountName: filebeat
      terminationGracePeriodSeconds: 30
      containers:
        - name: filebeat
          image: elastic/filebeat:8.11.3
          args: ["-c", "/etc/filebeat/filebeat.yml", "-e"]
          securityContext:
            runAsUser: 0
          resources:
            requests:
              cpu: 100m
              memory: 200Mi
            limits:
              cpu: 500m
              memory: 500Mi
          volumeMounts:
            - name: config
              mountPath: /etc/filebeat/filebeat.yml
              subPath: filebeat.yml
            - name: varlog
              mountPath: /var/log
              readOnly: true
            - name: containers
              mountPath: /var/lib/docker/containers
              readOnly: true
            - name: data
              mountPath: /usr/share/filebeat/data
          env:
            - name: NODE_NAME
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
      
      volumes:
        - name: config
          configMap:
            name: filebeat-config
        - name: varlog
          hostPath:
            path: /var/log
        - name: containers
          hostPath:
            path: /var/lib/docker/containers
        - name: data
          emptyDir: {}

---
apiVersion: v1
kind: ConfigMap
metadata:
  name: filebeat-config
  namespace: logging
data:
  filebeat.yml: |
    filebeat.inputs:
      # K8s容器日志
      - type: container
        enabled: true
        paths:
          - /var/log/containers/*.log
        processors:
          - add_kubernetes_metadata:
              host: ${NODE_NAME}
              matchers:
                - logs_path:
                    logs_path: "/var/log/containers/"
          - decode_json_fields:
              fields: ["message"]
              target: ""
              overwrite_keys: true
              add_error_key: true
      
      # Nginx日志
      - type: container
        enabled: true
        paths:
          - /var/log/containers/*nginx*.log
        processors:
          - add_kubernetes_metadata:
              host: ${NODE_NAME}
          - dissect:
              tokenizer: '%{client_ip} - %{remote_user} [%{timestamp}] "%{method} %{path} HTTP/%{http_version}" %{status_code} %{body_bytes_sent} "%{referrer}" "%{user_agent}" %{response_time}'
              field: "message"
              target_prefix: "nginx"
      
      # Java应用日志（多行合并）
      - type: container
        enabled: true
        paths:
          - /var/log/containers/*java*.log
        multiline.type: pattern
        multiline.pattern: '^\d{4}-\d{2}-\d{2}'
        multiline.negate: true
        multiline.match: after
        multiline.max_lines: 500
        processors:
          - add_kubernetes_metadata:
              host: ${NODE_NAME}
    
    # 输出到Elasticsearch
    output.elasticsearch:
      hosts: ["https://es-data-hot-0.es-data-hot.logging:9200"]
      username: "elastic"
      password: "${ELASTIC_PASSWORD}"
      ssl.certificate_authorities: ["/etc/filebeat/certs/ca.crt"]
      index: "enterprise-logs-%{+yyyy.MM.dd}"
      bulk_max_size: 5000
      worker: 4
      loadbalance: true
    
    # 处理器
    processors:
      - add_host_metadata:
          when.not.contains.tags: forwarded
      - add_cloud_metadata: ~
      - add_docker_metadata: ~
      - drop_fields:
          fields: ["agent.ephemeral_id", "agent.id"]
      
    # 监控
    monitoring.enabled: true
    monitoring.elasticsearch:
      hosts: ["https://es-master-0:9200"]
```

---

## 六、Kibana部署

```yaml
# kibana-deployment.yaml
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kibana
  namespace: logging
spec:
  replicas: 2
  selector:
    matchLabels:
      app: kibana
  template:
    spec:
      containers:
        - name: kibana
          image: kibana:8.11.3
          env:
            - name: ELASTICSEARCH_HOSTS
              value: '["https://es-master-0:9200","https://es-master-1:9200","https://es-master-2:9200"]'
            - name: ELASTICSEARCH_USERNAME
              value: "kibana_system"
            - name: ELASTICSEARCH_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: elasticsearch-credentials
                  key: kibana_system
            - name: SERVER_NAME
              value: "kibana.internal.com"
          ports:
            - containerPort: 5601
          resources:
            requests:
              cpu: "1"
              memory: 2Gi
            limits:
              cpu: "2"
              memory: 4Gi
          readinessProbe:
            httpGet:
              path: /api/status
              port: 5601
            initialDelaySeconds: 30
            periodSeconds: 10

---
apiVersion: v1
kind: Service
metadata:
  name: kibana
  namespace: logging
spec:
  selector:
    app: kibana
  ports:
    - port: 5601
  type: LoadBalancer
  loadBalancerIP: 10.10.10.211
```

---

## 七、常用Kibana Dashboard查询

```json
// Nginx 5xx错误率
{
  "query": {
    "bool": {
      "must": [
        { "term": { "service": "nginx" } },
        { "range": { "nginx.status_code": { "gte": 500 } } }
      ]
    }
  },
  "aggs": {
    "5xx_over_time": {
      "date_histogram": {
        "field": "@timestamp",
        "fixed_interval": "5m"
      }
    }
  }
}

// Java应用错误日志
{
  "query": {
    "bool": {
      "must": [
        { "term": { "level": "ERROR" } },
        { "wildcard": { "service": "*java*" } }
      ]
    }
  },
  "sort": [{ "@timestamp": { "order": "desc" } }]
}

// 按Pod统计日志量
{
  "size": 0,
  "aggs": {
    "by_pod": {
      "terms": { "field": "pod", "size": 50 },
      "aggs": {
        "by_level": {
          "terms": { "field": "level" }
        }
      }
    }
  }
}
```

---

## 八、一键部署

```bash
#!/bin/bash
# install_efk.sh - 一键部署EFK日志平台

set -euo pipefail

echo "Step 1: 创建命名空间和密钥..."
kubectl create namespace logging

kubectl create secret generic elasticsearch-credentials \
  --from-literal=elastic=Elastic@Admin2024 \
  --from-literal=kibana_system=Kibana@2024 \
  -n logging

echo "Step 2: 部署Elasticsearch集群..."
kubectl apply -f elasticsearch-statefulset.yaml

echo "Step 3: 等待ES集群就绪..."
kubectl -n logging rollout status statefulset/es-master --timeout=600s
kubectl -n logging rollout status statefulset/es-data-hot --timeout=600s

echo "Step 4: 初始化ILM策略..."
kubectl -n logging exec es-master-0 -- curl -s -X PUT \
  "https://localhost:9200/_ilm/policy/enterprise-logs-policy" \
  -H 'Content-Type: application/json' \
  -u elastic:Elastic@Admin2024 \
  -k -d @ilm-policy.json

echo "Step 5: 创建Index Template..."
kubectl -n logging exec es-master-0 -- curl -s -X PUT \
  "https://localhost:9200/_index_template/enterprise-logs" \
  -H 'Content-Type: application/json' \
  -u elastic:Elastic@Admin2024 \
  -k -d @index-template.json

echo "Step 6: 部署Kibana..."
kubectl apply -f kibana-deployment.yaml

echo "Step 7: 部署Filebeat..."
kubectl apply -f filebeat-daemonset.yaml

echo "Step 8: 部署Logstash (可选)..."
kubectl apply -f logstash-deployment.yaml

echo "✅ EFK日志平台部署完成"
echo "Kibana: http://10.10.10.211"
```

---

> 本项目基于25个语雀知识库(2699篇,584万字)编写
