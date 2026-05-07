# 企业级ELK/EFK日志分析平台

> 完整实现企业级日志收集、存储、检索、可视化全链路
> 覆盖: Elasticsearch集群 + Filebeat + Kibana + ILM生命周期 + 安全加固

> **⚠️ 版本说明**：本文档基于2026年5月最新版本编写。
> - Elasticsearch 8.17.x (最新稳定版，安全功能默认启用)
> - Kibana 8.17.x (最新稳定版)
> - Filebeat 8.17.x (最新稳定版)
> - Kafka 3.9+ (支持KRaft模式，无ZooKeeper依赖)
> - Logstash 8.17.x (最新稳定版)
> 
> **2026年日志方案趋势**：
> - **Grafana Loki** 在K8s场景更轻量，成本比ELK低60-80%
> - **Vector** 替代Filebeat/Fluentd，性能更好，资源消耗更低
> - **ClickHouse** 替代Elasticsearch用于结构化日志分析
> - 本项目使用ELK方案，如需轻量方案可考虑Loki+Vector组合
>
> **Kafka模式选择**：
> - **KRaft模式**（推荐）：无ZooKeeper依赖，部署更简单，性能更好
> - **ZooKeeper模式**（传统）：兼容性好，但需要额外维护ZooKeeper集群
> - 本项目使用KRaft模式

---

## 2026年日志方案对比

| 方案 | 优势 | 劣势 | 适用场景 | 成本 |
|------|------|------|----------|------|
| **ELK (Elasticsearch)** | 功能全面，生态成熟 | 资源消耗高，成本高 | 大规模日志分析 | 高 |
| **Grafana Loki** | 轻量级，成本低60-80% | 查询能力较弱 | K8s环境 | 低 |
| **ClickHouse** | 列式存储，查询快 | 运维复杂度高 | 结构化日志 | 中 |
| **Vector + Loki** | 性能最优，资源消耗最低 | 功能相对简单 | 轻量级场景 | 最低 |

> **推荐选择**：
> - **大规模企业级**：ELK (本项目方案)
> - **K8s轻量级**：Loki + Vector (成本最优)
> - **高性能查询**：ClickHouse (结构化日志)

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
| Elasticsearch Data-Cold | 2 | 4C/16G/10T HDD | 冷数据(90天) |
| Kibana | 2 | 4C/8G/50G | 可视化 |
| Logstash | 3 | 8C/16G/100G | 日志转换 |
| Filebeat | DaemonSet | - | 日志采集 |

> **生产建议**: 大规模集群(>50节点)建议增加:
> - Ingest节点(2-3个): 处理日志解析,减少Data节点CPU压力
> - Coordinating节点(2-3个): 处理查询请求,与数据节点分离
> - 冷节点: searchable_snapshot场景可减至1个

---

## 三、Elasticsearch集群部署

> **生产环境节点角色分离建议**:
> - Master节点: 3台,仅负责集群管理(不存储数据)
> - Data-Hot节点: 存储近期数据(30天),SSD存储
> - Data-Warm节点: 存储历史数据(90天),HDD存储
> - Data-Cold节点: 存储归档数据(365天),对象存储
> - Ingest节点: 处理日志解析(可选)
> - Coordinating节点: 处理客户端请求(可选)

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
    # [重要] node.roles不能在ConfigMap中静态定义，因为不同节点角色需要不同值(master/data/coordinating)
    # 必须通过Pod spec的env字段注入环境变量，在StatefulSet/Deployment中按角色分别配置:
    #   master角色:  env: [{name: NODE_ROLES, value: "master"}]
    #   data角色:    env: [{name: NODE_ROLES, value: "data"}]
    #   hot角色:     env: [{name: NODE_ROLES, value: "data_hot"}]
    #   warm角色:    env: [{name: NODE_ROLES, value: "data_warm"}]
    #   cold角色:    env: [{name: NODE_ROLES, value: "data_cold"}]
    #   coordinating: env: [{name: NODE_ROLES, value: ""}]
    # 通过环境变量${NODE_ROLES}注入，ConfigMap本身无法区分节点角色
    # node.roles 通过各StatefulSet/Deployment的env字段按角色注入(NODE_ROLES)
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

> **[证书管理建议]** 生产环境推荐使用 cert-manager 自动管理证书:
> - 创建Issuer/ClusterIssuer使用CA签发(如Let's Encrypt或内部CA)
> - 创建Certificate资源自动生成TLS Secret，挂载到Pod
> - cert-manager支持自动轮转(默认到期前30天)，避免证书过期导致集群中断
> - transport层证书可使用self-signed + cert-manager CA策略
> - 详见: https://cert-manager.io/docs/usage/ingress/

  jvm.options: |
    -Xms4g
    -Xmx4g
    -XX:+UseG1GC
    -XX:G1HeapRegionSize=2m
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
          # [注意] 这只在Pod运行时生效。节点重启后需在初始化脚本中持久化:
          # echo "vm.max_map_count=262144" >> /etc/sysctl.d/99-elasticsearch.conf && sysctl -p
          # 节点初始化时持久化(非Pod内):
          # echo "vm.max_map_count=262144" > /etc/sysctl.d/99-elasticsearch.conf
          # sysctl -p /etc/sysctl.d/99-elasticsearch.conf

> vm.max_map_count必须在节点层面持久化,Pod重启后不会自动恢复

> **[sysctl持久化方案]** 以下方法可确保vm.max_map_count在节点重启后自动生效:
> 1. **kubelet配置**(推荐): 在Node的kubelet.config.yaml中配置systemReserved/systemAllowedUnsafeSysctls
> 2. **DaemonSet预置**: 部署init DaemonSet自动在每个节点写入/etc/sysctl.d/99-elasticsearch.conf
> 3. **节点镜像预置**: 在Node自定义镜像中预置sysctl配置
> ```bash
> # 验证当前节点设置
> sysctl vm.max_map_count
> # 预期输出: vm.max_map_count = 262144
> ```

      containers:
        - name: elasticsearch
          image: elasticsearch:8.17.0
          ports:
            - containerPort: 9200  # ES端口
              name: http
            - containerPort: 9300
              name: transport
          env:
            - name: NODE_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
            - name: NODE_ROLES
              value: "master"
            - name: ES_JAVA_OPTS
              value: "-Xms4g -Xmx4g"  # [注意] 此值覆盖上方jvm.options中的-Xms/-Xmx，生产环境需保持一致
            - name: ELASTIC_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: elasticsearch-credentials
                  key: elastic

> **[API Key认证]** 生产环境建议使用API Key替代密码认证:
> ```bash
> # 创建带集群权限的API Key
> curl -u elastic:password -X POST 'https://es-master:9200/_security/api_key' \
>   -H 'Content-Type: application/json' -d '{
>   "name": "logstash-api-key",
>   "role_descriptors": {
>     "logstash_writer": {
>       "cluster": ["manage_index_templates", "monitor"],
>       "index": [{"names": ["enterprise-logs-*"], "privileges": ["write", "create_index"]}]
>     }
>   },
>   "expiration": "365d"
> }'
> ```
> API Key比密码更安全，支持细粒度权限控制和自动过期。
          resources:
            requests:
              cpu: "4"
              memory: 32Gi
            limits:
              cpu: "8"
              memory: 32Gi
          volumeMounts:
            - name: elasticsearch-data
              mountPath: /usr/share/elasticsearch/data
            - name: config
              mountPath: /usr/share/elasticsearch/config/elasticsearch.yml
              subPath: elasticsearch.yml
            # [修复] jvm.options ConfigMap已定义但未挂载到容器
            - name: config
              mountPath: /usr/share/elasticsearch/config/jvm.options
              subPath: jvm.options
          readinessProbe:
            httpGet:
              path: /_cluster/health?local=true
              port: 9200  # ES端口
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
# 创建local-ssd StorageClass(需要预先在节点上准备磁盘)
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: local-ssd
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Retain

> local-ssd需要预先在K8s节点上挂载SSD磁盘,并创建对应的Local PV

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
          image: elasticsearch:8.17.0
          env:
            - name: NODE_ROLES
              value: "data_hot,ingest"
            - name: ES_JAVA_OPTS
              value: "-Xms31g -Xmx31g"  # 64G物理内存,堆不超过32G压缩指针阈值
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
          "searchable_snapshot": { "snapshot_repository": "cold-backup" }  # [已修复] freeze在ES 8.x已废弃
        }
      },
      "delete": {
        "min_age": "365d",
        "actions": {
          "delete": {}
        }
      }
    }
  }
}
```

> **[前置步骤] 创建Snapshot仓库**: ILM的searchable_snapshot需要先注册snapshot仓库。
> 如果不先创建仓库,ILM在cold阶段会因找不到`cold-backup`仓库而失败。

```bash
# [必须] 在ILM策略生效前创建snapshot仓库
# 1. 注册S3/OSS仓库(与section 16.2中使用的仓库同名)
curl -k -X PUT 'https://es-master:9200/_snapshot/cold-backup' \
  -H 'Content-Type: application/json' -d '{
  "type": "s3",
  "settings": {
    "bucket": "enterprise-es-snapshots",
    "region": "oss-cn-hangzhou",
    "base_path": "enterprise-logs/cold",
> 国内环境使用阿里云OSS,endpoint: https://oss-cn-hangzhou.aliyuncs.com
    "compress": true,
    "server_side_encryption": true
  }
}'

# 2. 验证仓库连通性
curl -k -X POST 'https://es-master:9200/_snapshot/cold-backup/_verify'

# 3. [可选] 如果使用共享文件系统(NFS)代替S3
# curl -k -X PUT 'https://es-master:9200/_snapshot/cold-backup' \
#   -H 'Content-Type: application/json' -d '{
#   "type": "fs",
#   "settings": {
  # "location": "/mnt/nfs/es-snapshots",
#     "compress": true
#   }
# }'
```

> **执行顺序**: 必须先创建Snapshot仓库(第16.2节),再应用ILM策略。否则Cold阶段的searchable_snapshot会失败。

```bash
# 创建Index Template
curl -k -X PUT "https://es-master-0:9200/_index_template/enterprise-logs" -H 'Content-Type: application/json' -d'
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
        "user_agent": { "type": "keyword" },
        "thread.name": { "type": "keyword" },
        "logger.name": { "type": "keyword" }
      }
    }
  },
  "priority": 200
}'
```

> Java应用日志通常包含thread和logger字段,用于按线程/类名聚合分析

---

## 五、Filebeat DaemonSet

> **生产环境Filebeat配置要点**:
> - Registry持久化: 使用hostPath或PVC持久化registry文件,防止Pod重启后日志重复发送
> - multiline处理: 合并多行日志(如Java异常堆栈)
> - drop_fields: 删除不需要的字段减少存储开销
> - processors: 添加kubernetes元数据、过滤系统日志

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
      terminationGracePeriodSeconds: 60
      # 日志缓冲场景需要更长的grace period确保数据刷盘
      containers:
        - name: filebeat
          image: elastic/filebeat:8.17.0
          args: ["-c", "/etc/filebeat/filebeat.yml", "-e"]
          securityContext:
            runAsUser: 0
            runAsGroup: 0  # root required for hostPath log access
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
              mountPath: /var/log/pods  # [已修复] containerd环境请改为/var/log/pods/
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
            path: /var/log/pods
        - name: data
          hostPath:
            path: /var/lib/filebeat
            type: DirectoryOrCreate

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

> **注意**: 此dissect模式匹配标准Nginx combined日志格式。如使用自定义格式(如JSON),需调整tokenizer。建议使用Filebeat Nginx Module自动适配。

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
        # 注意: 此模式匹配YYYY-MM-DD格式。如日志使用其他格式(如DD/MMM/YYYY),需调整pattern。建议:
        # pattern: '^[\d]{4}-[\d]{2}-[\d]{2}|^[\d]{2}/[\w]{3}/[\d]{4}'
        # multiline.max_lines: 1000  # 深层嵌套异常可能超过500行
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

> **⚠️ 默认配置**: 此处使用直连ES(轻量方案)。生产环境推荐使用Kafka缓冲+Logstash处理:
> output.kafka:
>   hosts: ["kafka-0.kafka:9092","kafka-1.kafka:9092","kafka-2.kafka:9092"]
>   topic: "filebeat-logs"
> 然后Logstash消费Kafka并输出到ES。详见第13.4节

---

## 六、Kafka缓冲层(可选但推荐)

> **Kafka生产环境运维要点**:
> - 模式选择: KRaft(无ZooKeeper依赖,推荐) vs ZooKeeper(传统)
> - 分区策略: 日志topic建议分区数=消费者数,保证并行消费
> - 副本因子: 生产环境至少replication.factor=3
> - 消费者组: 监控consumer lag,避免消费堆积

> **[推荐]** 生产环境建议在Filebeat和Logstash之间部署Kafka作为缓冲层，
> 防止ES写入压力反压导致Filebeat日志丢失。

```yaml
# kafka-statefulset.yaml
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: kafka
  namespace: logging
spec:
  serviceName: kafka
  replicas: 3
  selector:
    matchLabels:
      app: kafka
  template:
    metadata:
      labels:
        app: kafka
    spec:
      containers:
      - name: kafka
        image: bitnami/kafka:3.9
        env:
        - name: KAFKA_CFG_NODE_ID
          value: "0"  # StatefulSet ordinal, kafka-0=0, kafka-1=1, kafka-2=2
        - name: KAFKA_CFG_PROCESS_ROLES
          value: "broker,controller"
        - name: KAFKA_CFG_CONTROLLER_QUORUM_VOTERS
          value: "0@kafka-0.kafka:9093,1@kafka-1.kafka:9093,2@kafka-2.kafka:9093"
        - name: KAFKA_CFG_LISTENERS
          value: "PLAINTEXT://:9092,CONTROLLER://:9093"
        - name: KAFKA_CFG_ADVERTISED_LISTENERS
          value: "PLAINTEXT://$(POD_NAME).kafka:9092,CONTROLLER://$(POD_NAME).kafka:9093"
        - name: POD_NAME
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        - name: KAFKA_CFG_LOG_RETENTION_HOURS
          value: "168"  # 7天
        - name: KAFKA_CFG_LOG_RETENTION_BYTES
          value: "1073741824"  # 1GB
        ports:
        - containerPort: 9092
          name: plaintext
        - containerPort: 9093
          name: controller
        resources:
          requests:
            cpu: 500m
            memory: 4Gi   # Kafka生产环境建议4-8GB
          limits:
            cpu: 2000m
            memory: 8Gi
        volumeMounts:
        - name: data
          mountPath: /bitnami/kafka
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: ["ReadWriteOnce"]
        resources:
          requests:
            storage: 200Gi  # 日志缓冲需要更大空间
---
apiVersion: v1
kind: Service
metadata:
  name: kafka
  namespace: logging
spec:
  selector:
    app: kafka
  ports:
  - port: 9092
    name: plaintext
```

> **⚠️ KRaft模式要求node.id为数字。StatefulSet的ordinal(0,1,2)通过hostname提取，不能直接使用metadata.name(返回"kafka-0"字符串)。**
> 每个broker的KAFKA_CFG_NODE_ID需手动指定对应序号。

> **⚠️ 日志缓冲场景建议200Gi+,高峰期日志量可能突增**

> Kafka需要JMX Exporter暴露metrics供Prometheus抓取

> ```yaml
> # JMX Exporter配置
> - name: KAFKA_OPTS
>   value: "-javaagent:/opt/bitnami/kafka/jmx_prometheus_javaagent.jar=9308:/opt/bitnami/kafka/jmx_prometheus_jmx_exporter.yml"
> ```

> # Kafka Exporter部署
> ```yaml
> image: danielqsj/kafka-exporter:latest
> args:
>   - --kafka.server=kafka-0.kafka:9092
>   - --kafka.topic.filter=.*
> ```
> Kafka需要专用Exporter暴露消费者组lag、分区数量等metrics

> **[Kafka Exporter完整部署]** 建议以独立Deployment部署Kafka Exporter:
> ```yaml
> # kafka-exporter.yaml
> ---
> apiVersion: apps/v1
> kind: Deployment
> metadata:
>   name: kafka-exporter
>   namespace: logging
>   labels:
>     app: kafka-exporter
> spec:
>   replicas: 1
>   selector:
>     matchLabels:
>       app: kafka-exporter
>   template:
>     metadata:
>       labels:
>         app: kafka-exporter
>       annotations:
>         prometheus.io/scrape: "true"
>         prometheus.io/port: "9308"
>     spec:
>       containers:
>       - name: kafka-exporter
>         image: danielqsj/kafka-exporter:latest
>         args:
>         - --kafka.server=kafka-0.kafka:9092,kafka-1.kafka:9092,kafka-2.kafka:9092
>         - --kafka.topic.filter=.*
>         - --kafka.group.filter=.*
>         ports:
>         - containerPort: 9308
>           name: http
>         resources:
>           requests:
>             cpu: 100m
>             memory: 128Mi
>           limits:
>             cpu: 200m
>             memory: 256Mi
> ---
> apiVersion: v1
> kind: Service
> metadata:
>   name: kafka-exporter
>   namespace: logging
>   labels:
>     app: kafka-exporter
> spec:
>   ports:
>   - port: 9308
>     name: http
>     targetPort: 9308
>   selector:
>     app: kafka-exporter
> ```
> 关键metrics: kafka_consumergroup_lag(消费延迟)、kafka_topic_partitions(分区数)、kafka_brokers(broker数)
> 配合ServiceMonitor或PodMonitor自动发现抓取。

> Filebeat配置中将output改为Kafka:
> ```yaml
> output.kafka:
>   hosts: ["kafka-0.kafka:9092", "kafka-1.kafka:9092", "kafka-2.kafka:9092"]
>   topic: "filebeat-logs"
> ```
> Logstash input改为Kafka:
> ```ruby
> input {
>   kafka {
>     bootstrap_servers => "kafka-0.kafka:9092"
>     topics => ["filebeat-logs"]
>     group_id => "logstash-consumers"
>   }
> }
> ```

---

## ELK深度健康检查脚本

```bash
#!/bin/bash
# elk-deep-check.sh - ELK深度健康检查
set -euo pipefail

ES_HOST="http://elasticsearch:9200"
KIBANA_HOST="http://kibana:5601"
KAFKA_HOST="kafka-0.kafka:9092"

echo "===== ELK深度健康检查 ====="

# 1. ES集群健康状态
echo "1. Elasticsearch集群状态:"
curl -s ${ES_HOST}/_cluster/health | jq '{status, number_of_nodes, active_shards}'

# 2. ES索引ILM状态
echo "2. ILM生命周期状态:"
curl -s ${ES_HOST}/_ilm/explain/filebeat-* | jq '.indices | to_entries[] | {key, value: {step, step_info}}' | head -20

# 3. ES磁盘使用率
echo "3. ES磁盘使用率:"
curl -s ${ES_HOST}/_cat/allocation?v | grep -E 'heap|disk'

# 4. Kafka消费者组滞后
echo "4. Kafka消费者组滞后:"
kubectl exec -it kafka-0 -n logging -- kafka-consumer-groups.sh \
  --bootstrap-server localhost:9092 \
  --describe --group logstash-consumers 2>/dev/null | grep -E 'TOPIC|filebeat'

# 5. Filebeat状态
echo "5. Filebeat状态:"
kubectl get pods -n logging -l app=filebeat -o custom-columns='NAME:.metadata.name,STATUS:.status.phase,RESTARTS:.status.containerStatuses[0].restartCount'

# 6. Filebeat注册表文件
echo "6. Filebeat注册表(检查日志偏移量):"
kubectl exec -it $(kubectl get pod -n logging -l app=filebeat -o jsonpath='{.items[0].metadata.name}') -n logging -- cat /var/lib/filebeat/registry/filebeat/log.json 2>/dev/null | tail -5

# 7. Kibana状态
echo "7. Kibana状态:"
curl -s ${KIBANA_HOST}/api/status | jq '.status.overall'

# 8. ES JVM内存使用
echo "8. ES JVM内存使用:"
curl -s "${ES_HOST}/_nodes/jvm" | jq '.nodes | to_entries[] | {name: .value.name, heap_used: .value.jvm.mem.heap_used_in_bytes, heap_max: .value.jvm.mem.heap_max_in_bytes}'

echo ""
echo "===== 健康检查完成 ====="
```

---

## 七、Kibana部署
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
          image: kibana:8.17.0
          env:
            - name: ELASTICSEARCH_HOSTS
              value: '["https://es-master-0:9200","https://es-master-1:9200","https://es-master-2:9200"]'

> 生产建议: 使用K8s Service名称替代硬编码Pod名称:
> ELASTICSEARCH_HOSTS: https://es-master.logging.svc.cluster.local:9200

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
  type: ClusterIP
  selector:
    app: kibana
  ports:
    - port: 5601
      targetPort: 5601
```

> ⚠️ **安全声明**: 本文档中的密码(如${MYSQL_ROOT_PASSWORD}、${HARBOR_ADMIN_PASSWORD}等)均为示例占位符。
> 生产环境必须使用密钥管理工具(Vault/K8s Secrets/环境变量)管理敏感信息，
> 切勿将真实密码硬编码在配置文件或脚本中。

## 九、Elasticsearch性能调优

### 9.1 JVM调优

> **[统一说明]** JVM堆配置在本文档多处出现(ConfigMap jvm.options、StatefulSet ES_JAVA_OPTS、本节)。
> 生产环境请统一以本节推荐值为准，确保所有位置的 -Xms/-Xmx 一致。
> ES_JAVA_OPTS 环境变量优先级高于 jvm.options 文件。

```bash
# /etc/elasticsearch/jvm.options
# 堆内存: 不超过物理内存的50%，不超过32GB(压缩指针上限)
-Xms31g
-Xmx31g

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
      "dynamic": true,

> 日志场景使用 dynamic: true 以容忍新字段自动映射，避免索引写入失败

      "properties": {
        "@timestamp": { "type": "date" },
        "message": { "type": "text", "analyzer": "ik_max_word" },
        "level": { "type": "keyword" },
        "service": { "type": "keyword" },
        "trace_id": { "type": "keyword" },
        "response_time": { "type": "float" },
        "status_code": { "type": "short" },
        "error.message": { "type": "text", "analyzer": "ik_max_word" },
        "error.type": { "type": "keyword" },
        "error.stack_trace": { "type": "text" },
        "exception.class": { "type": "keyword" },
        "exception.message": { "type": "text", "analyzer": "ik_max_word" }
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
curl -s -k 'https://es-master:9200/_cluster/health?pretty'

# 2. 查看未分配分片
curl -s -k 'https://es-master:9200/_cluster/allocation/explain?pretty'

# 3. 强制分配分片(数据会丢失)
curl -X POST -k 'https://es-master:9200/_cluster/reroute' -H 'Content-Type: application/json' -d '{
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

### 11.1 数据量与节点规划

| 日数据量 | 热节点(30天) | 温节点(90天) | 冷节点(365天) | Master | 总节点 | JVM堆 | 月成本(阿里云) |
|----------|-------------|-------------|--------------|--------|--------|-------|---------------|
| 100GB/天 | 3×2TB SSD | 2×4TB HDD | 1×10TB HDD | 3 | 9 | 16G | ~15,000元 |
| 500GB/天 | 5×4TB SSD | 3×8TB HDD | 2×16TB HDD | 3 | 13 | 16G | ~35,000元 |
| 1TB/天 | 8×4TB SSD | 5×10TB HDD | 3×20TB HDD | 3 | 19 | 16G | ~65,000元 |

> **JVM堆规则**: 堆内存 ≤ 物理内存的50%，且不超过32GB(压缩指针阈值)
> **分片规则**: 单分片20-50GB，分片数=节点数×1~3

### 11.2 ILM热温冷架构

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
          "set_priority": { "priority": 100 }
        }
      },
      "warm": {
        "min_age": "7d",
        "actions": {
          "shrink": { "number_of_shards": 1 },
          "forcemerge": { "max_num_segments": 1 },
          "set_priority": { "priority": 50 }
        }
      },
      "cold": {
        "min_age": "30d",
        "actions": {
          "searchable_snapshot": { "snapshot_repository": "cold-backup" },
          "set_priority": { "priority": 0 }
        }
      },
      "delete": {
        "min_age": "365d",
        "actions": {
          "delete": {}
        }
      }
    }
  }
}
```

### 11.3 节点角色分配

| 角色 | 节点标签 | 存储类型 | JVM堆 | 用途 |
|------|---------|---------|-------|------|
| Master | node-role: master | SSD 100G | 4G | 集群管理、元数据 |
| Hot | node-role: hot | NVMe/SSD 2-4TB | 16G | 最近30天数据，高IO |
| Warm | node-role: warm | HDD 4-10TB | 16G | 30-90天数据，读多写少 |
| Cold | node-role: cold | HDD 10-20TB | 8G | 90-365天数据，偶尔查询 |

```bash
# 为节点打标签
kubectl label node es-hot-01 node-role.kubernetes.io/es-hot: ""
kubectl label node es-warm-01 node-role.kubernetes.io/es-warm: ""
kubectl label node es-cold-01 node-role.kubernetes.io/es-cold: ""
```

> **成本优化**: 冷节点使用HDD+searchable_snapshot，存储成本降低70%
> **查询优化**: 日常查询只走热节点，历史查询走温节点，极少查询走冷节点

---

## 十二、运维SOP

```bash
#!/bin/bash
# elk_daily_check.sh - ELK日常巡检

echo "========== ELK日常巡检 =========="

# 1. ES集群状态
curl -s -k 'https://es-master:9200/_cluster/health?pretty' | grep -E "status|number_of_nodes|unassigned_shards"

# 2. 索引统计
curl -s -k 'https://es-master:9200/_cat/indices?v&s=store.size:desc&h=index,health,status,docs.count,store.size' | head -20

... [OUTPUT TRUNCATED - 545 chars omitted out of 50545 total] ...

e: KAFKA_HEAP_OPTS
              value: "-Xmx4g -Xms4g"
        resources:
          requests:
            cpu: 500m
            memory: 4Gi   # Kafka生产环境建议4-8GB
          limits:
            cpu: 2000m
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
            storage: 200Gi
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
  --config retention.ms=604800000 \
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
  --group logstash-consumers \
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
    required_acks: -1
    compression: lz4
    max_message_bytes: 1000000
    worker: 4

  # 背压处理
  queue.mem:
    events: 8192

> required_acks: -1(all)保证所有副本确认写入,防止数据丢失
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
    group_id => "logstash-consumers"
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

  # Logstash死信队列配置
  if "_grokparsefailure" in [tags] or "_jsonparsefailure" in [tags] {
    file {
      path => "/usr/share/logstash/dead-letter/%{+YYYY-MM-dd}.log"
      codec => json
    }
  }
}
```

> 解析失败的日志应发送到DLQ而非丢弃,便于后续分析和修复

> **[DLQ完整配置]** 除output中的dead_letter_path外，还需在logstash.yml中启用DLQ:
> ```yaml
> # logstash.yml
> dead_letter_queue.enable: true
> dead_letter_queue.max_queue_size: 1024mb
> dead_letter_queue.flush_interval: 1000
> ```
> 同时建议挂载PVC持久化DLQ目录，防止Pod重启后DLQ数据丢失。

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

# 2. 更新索引模板
curl -X PUT 'http://es-master:9200/_index_template/enterprise-logs' -H 'Content-Type: application/json' -d '{
  "index_patterns": ["enterprise-logs-*"],
  "template": {
    "mappings": {
      "dynamic": true,
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
    "dynamic": true,
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
  --group logstash-consumers --describe

# GROUP              TOPIC           PARTITION  CURRENT-OFFSET  LOG-END-OFFSET  LAG
# logstash-consumers  elk-logs        0          1234567         1235678         1111
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
    --group logstash-consumers --describe | \
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

> **License要求**: CCR(跨集群复制)需要Platinum/Enterprise License。开源替代方案:
> - Logstash跨集群同步
> - Kafka MirrorMaker 2
> - 阿里云ES的DTS数据传输服务

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
vm.swappiness=1  # [生产建议] 应设为0或执行swapoff -a完全关闭swap，避免Redis数据被换出到磁盘
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
    # [修复] 移除cluster-level强制路由到hot节点的设置
    # 该设置会导致master/data-warm节点无法分配分片，影响集群健康
    # 应在index template级别设置routing.allocation.require.node_role
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
```
> **性能提示**: query_string性能较差且易出错。生产环境建议使用match或simple_query_string替代。

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
```
> **注意**: terminate_after会提前终止搜索,可能导致结果不准确。生产环境建议移除此参数或增大到10000。

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
    "region": "oss-cn-hangzhou",
    "base_path": "enterprise-logs",
> 国内环境使用阿里云OSS,endpoint: https://oss-cn-hangzhou.aliyuncs.com
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

> **实际RTO**: DNS传播+数据验证可能增加5-10分钟。建议提前配置DNS TTL=60s,并在切换前验证目标集群数据完整性。

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

## 十七、日志采样与保留策略

### 日志量级估算
| 日志源 | 日均条数 | 平均大小 | 日存储量 |
|--------|----------|----------|----------|
| 应用日志 | 100万 | 500B | 500MB |
| Nginx访问日志 | 500万 | 200B | 1GB |
| K8s审计日志 | 100万 | 300B | 300MB |
| **合计** | **700万** | - | **1.8GB** |

### 采样策略

| 日志级别 | 采集率 | 说明 |
|----------|--------|------|
| ERROR/FATAL | 100% | 完整采集，便于排查 |
| WARN | 100% | 完整采集，监控预警 |
| INFO | 采样10% | 通过hash采样保持同一请求的日志一致性 |
| DEBUG | 0% | 生产环境不采集 |

**Filebeat采样配置示例**:
```yaml
processors:
  - drop_event:
      when:
        and:
          - contains:
              message: "DEBUG"
          - not:
              has_fields: ["error", "exception"]
```

**采样影响说明**:
- 10% INFO采样意味着90%的正常请求日志丢失
- 同一请求的多条日志应全采或全不采(通过trace_id hash)
- 建议保留完整的ERROR/TRACE日志用于问题排查

### 保留策略

### 保留策略
- 热数据(30天): SSD存储
- 温数据(90天): HDD存储
- 冷数据(365天): 对象存储(OSS/S3)
- 归档数据(>365天): 压缩后归档

## 十八、成本估算

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
          # 生产环境应使用最新稳定版,查看https://github.com/prometheus-community/elasticsearch_exporter/releases
          args:
            - "--es.uri=https://elastic:${ELASTIC_PASSWORD}@es-master.logging.svc.cluster.local:9200"
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
openssl req -new -x509 -days 730 -key ca.key -out ca.crt -subj "/CN=Enterprise-ES-CA"

# 2. 生成HTTP证书
openssl genrsa -out http.key 2048
openssl req -new -key http.key -out http.csr -subj "/CN=es-master-0.elasticsearch.svc"
openssl x509 -req -days 730 -in http.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out http.crt

# 3. 生成Transport证书
openssl genrsa -out transport.key 2048
openssl req -new -key transport.key -out transport.csr -subj "/CN=transport"
openssl x509 -req -days 730 -in transport.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out transport.crt

# 4. 转换为PKCS12
openssl pkcs12 -export -in http.crt -inkey http.key -out http.p12 -password pass:changeit
openssl pkcs12 -export -in transport.crt -inkey transport.key -out transport.p12 -password pass:changeit

> 生产环境必须使用环境变量或Secret:
> export ES_PASSWORD=$(kubectl get secret es-elastic-user -o jsonpath='{.data.elastic}' | base64 -d)

# 5. 创建K8s Secret
kubectl create secret generic es-certs \
  --from-file=http.p12=http.p12 \
  --from-file=transport.p12=transport.p12 \
  --from-file=ca.crt=ca.crt \
  -n logging
```

> 证书有效期建议1-2年,配合cert-manager自动轮换

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

### 19.3 ES 8.x推荐使用API Key替代用户名密码
```yaml
# ES 8.x推荐使用API Key替代用户名密码
# 创建API Key:
# POST /_security/api_key
# {"name": "logstash", "role_descriptors": {"logstash_role": {"cluster": ["monitor"], "index": [{"names": ["logstash-*"], "privileges": ["write", "read"]}]}}
```
> API Key比用户名密码更安全,支持细粒度权限控制

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

> **等保三级要求**: 审计日志留存不少于180天。配置:
> - index.lifecycle.indexing_complete: true
> - 保留策略: Hot 7d → Warm 30d → Cold 180d → Delete
> - 使用ILM自动管理生命周期

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

> **低峰期升级**: Data-Hot节点升级会影响写入,必须在业务低峰期(如凌晨2-6点)执行。建议:
> 1. 通知业务团队
> 2. 监控写入QPS
> 3. 准备回滚方案

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
  elasticsearch=elasticsearch:8.17.0

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


## 监控告警: PrometheusRule配置

> **[PrometheusRule for Elasticsearch + ILM + Kafka]**
> 生产环境建议配合kube-prometheus-stack使用以下PrometheusRule进行自动告警。

```yaml
# prometheus-rules-elk.yaml
---
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: elasticsearch-alerts
  namespace: logging
  labels:
    release: prometheus
spec:
  groups:
  - name: elasticsearch.rules
    rules:
    - alert: ElasticsearchClusterRed
      expr: elasticsearch_cluster_health_status{color="red"} == 1
      for: 5m
      labels:
        severity: critical
      annotations:
        summary: "Elasticsearch集群状态RED"
        description: "ES集群 {{ $labels.cluster }} 状态为RED超过5分钟，可能存在分片丢失"

    - alert: ElasticsearchNodeDown
      expr: up{job="elasticsearch"} == 0
      for: 2m
      labels:
        severity: warning
      annotations:
        summary: "Elasticsearch节点离线"
        description: "ES节点 {{ $labels.instance }} 已离线超过2分钟"

    - alert: ElasticsearchJVMHeapHigh
      expr: elasticsearch_jvm_mem_used_bytes{area="heap"} / elasticsearch_jvm_mem_max_bytes{area="heap"} > 0.75
      for: 10m
      labels:
        severity: warning
      annotations:
        summary: "ES JVM堆内存使用率超过75%"
        description: "节点 {{ $labels.instance }} 堆内存使用率 {{ $value | humanizePercentage }}"

    - alert: ElasticsearchUnassignedShards
      expr: elasticsearch_cluster_health_unassigned_shards > 0
      for: 30m
      labels:
        severity: warning
      annotations:
        summary: "ES存在未分配分片"
        description: "集群存在 {{ $value }} 个未分配分片超过30分钟"

  - name: ilm.rules
    rules:
    - alert: ElasticsearchILMStepFailed
      expr: elasticsearch_ilm_step_status{status="ERROR"} == 1
      for: 15m
      labels:
        severity: warning
      annotations:
        summary: "ILM策略步骤执行失败"
        description: "索引 {{ $labels.index }} ILM步骤 {{ $labels.step }} 执行失败"

    - alert: ElasticsearchILMStuck
      expr: elasticsearch_ilm_step_milliseconds > 86400000
      for: 1h
      labels:
        severity: warning
      annotations:
        summary: "ILM策略执行卡住"
        description: "索引 {{ $labels.index }} 在步骤 {{ $labels.step }} 停留超过24小时"

  - name: kafka.rules
    rules:
    - alert: KafkaConsumerGroupLagHigh
      expr: kafka_consumergroup_lag_sum > 100000
      for: 15m
      labels:
        severity: warning
      annotations:
        summary: "Kafka消费者组延迟过高"
        description: "消费组 {{ $labels.consumergroup }} 延迟 {{ $value }} 条消息超过15分钟"

    - alert: KafkaBrokerDown
      expr: up{job="kafka-exporter"} == 0
      for: 2m
      labels:
        severity: critical
      annotations:
        summary: "Kafka Broker离线"
        description: "Kafka broker {{ $labels.instance }} 已离线"

    - alert: KafkaTopicUnderReplicated
      expr: kafka_topic_partition_replicas > kafka_topic_partition_in_sync_replica
      for: 10m
      labels:
        severity: warning
      annotations:
        summary: "Kafka Topic分区副本不足"
        description: "Topic {{ $labels.topic }} 分区 {{ $labels.partition }} 副本数不足"
```

> **部署方式**: kubectl apply -f prometheus-rules-elk.yaml
> 需要 kube-prometheus-stack 已部署，Prometheus会自动加载匹配label的PrometheusRule
> 建议同时配置Alertmanager路由到企业微信/钉钉/Slack通知渠道

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