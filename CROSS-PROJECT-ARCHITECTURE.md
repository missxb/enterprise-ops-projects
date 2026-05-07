# 跨项目架构设计文档

> 本文档定义10个企业级运维项目之间的联动设计，确保监控覆盖、日志关联、告警联动、安全统一、数据流完整、灾备设计。

---

## 一、整体架构数据流

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                              CI/CD 流水线                                        │
│  ┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐  │
│  │  GitLab  │───▶│ Jenkins  │───▶│  Harbor  │───▶│  ArgoCD  │───▶│   K8s    │  │
│  │ 代码仓库 │    │ 构建打包 │    │ 镜像仓库 │    │ GitOps   │    │ 集群     │  │
│  └──────────┘    └──────────┘    └──────────┘    └──────────┘    └──────────┘  │
│       │              │              │              │              │             │
│       │              ▼              │              │              │             │
│       │         ┌──────────┐       │              │              │             │
│       │         │ SonarQube│       │              │              │             │
│       │         │ 代码扫描 │       │              │              │             │
│       │         └──────────┘       │              │              │             │
│       │              │              │              │              │             │
│       │              ▼              │              │              │             │
│       │         ┌──────────┐       │              │              │             │
│       │         │  Trivy   │       │              │              │             │
│       │         │ 镜像扫描 │       │              │              │             │
│       │         └──────────┘       │              │              │             │
└─────────────────────────────────────────────────────────────────────────────────┘
                                       │
                                       ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│                              K8s 集群                                            │
│  ┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐  │
│  │   Kong   │───▶│ 微服务   │───▶│  MySQL   │    │  Redis   │    │   etcd   │  │
│  │   网关   │    │ (Pod)    │    │   MGR    │    │ Cluster  │    │  集群    │  │
│  └──────────┘    └──────────┘    └──────────┘    └──────────┘    └──────────┘  │
│       │              │              │              │              │             │
│       │              ▼              ▼              ▼              ▼             │
│       │         ┌─────────────────────────────────────────────────────┐         │
│       │         │              Prometheus + Grafana                   │         │
│       │         │              (监控告警体系)                         │         │
│       │         └─────────────────────────────────────────────────────┘         │
│       │                              │                                         │
│       │                              ▼                                         │
│       │         ┌─────────────────────────────────────────────────────┐         │
│       │         │              ELK/EFK 日志平台                      │         │
│       │         │              (日志收集分析)                         │         │
│       │         └─────────────────────────────────────────────────────┘         │
└─────────────────────────────────────────────────────────────────────────────────┘
```

---

## 二、监控覆盖设计

### 2.1 Exporter配置矩阵

| 组件 | Exporter | 端口 | 指标路径 | 项目 |
|------|----------|------|----------|------|
| Node | node_exporter | 9100 | /metrics | 01 |
| MySQL | mysqld_exporter | 9104 | /metrics | 05 |
| Redis | redis_exporter | 9121 | /metrics | 06 |
| Nginx | nginx-prometheus-exporter | 9113 | /metrics | 07 |
| Kong | kong-prometheus | 8444 | /metrics | 09 |
| Kubernetes | kube-state-metrics | 8080 | /metrics | 01 |
| Calico | calico-node | 9091 | /metrics | 01 |
| Harbor | harbor-metrics | 8001 | /metrics | 01 |

### 2.2 Prometheus抓取配置

```yaml
# prometheus-targets.yaml
scrape_configs:
  # Node Exporter
  - job_name: 'node-exporter'
    static_configs:
      - targets:
        - '10.10.10.11:9100'
        - '10.10.10.12:9100'
        - '10.10.10.21:9100'
        - '10.10.10.22:9100'
        - '10.10.10.23:9100'
        - '10.10.10.24:9100'
        - '10.10.10.25:9100'

  # MySQL Exporter
  - job_name: 'mysql-exporter'
    static_configs:
      - targets:
        - '10.10.10.41:9104'
        - '10.10.10.42:9104'
        - '10.10.10.43:9104'

  # Redis Exporter
  - job_name: 'redis-exporter'
    static_configs:
      - targets:
        - '10.10.10.51:9121'
        - '10.10.10.52:9121'
        - '10.10.10.53:9121'

  # Nginx Exporter
  - job_name: 'nginx-exporter'
    static_configs:
      - targets:
        - '10.10.10.61:9113'
        - '10.10.10.62:9113'

  # Kong Exporter
  - job_name: 'kong-exporter'
    static_configs:
      - targets:
        - '10.10.10.71:8444'
        - '10.10.10.72:8444'

  # Kubernetes API Server
  - job_name: 'kubernetes-apiserver'
    kubernetes_sd_configs:
      - role: endpoints
    scheme: https
    tls_config:
      ca_file: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
    bearer_token_file: /var/run/secrets/kubernetes.io/serviceaccount/token

  # Kubernetes Node
  - job_name: 'kubernetes-nodes'
    kubernetes_sd_configs:
      - role: node
    relabel_configs:
      - action: labelmap
        regex: __meta_kubernetes_node_label_(.+)
```

---

## 三、日志关联设计

### 3.1 Filebeat模块化配置

```yaml
# filebeat.yml
filebeat.inputs:
  # K8s Pod日志
  - type: container
    paths:
      - '/var/log/containers/*.log'
    processors:
      - add_kubernetes_metadata:
          host: ${NODE_NAME}
          matchers:
            - logs_path:
                logs_path: "/var/log/containers/"

  # MySQL慢查询日志
  - type: log
    paths:
      - '/var/log/mysql/slow.log'
    fields:
      log_type: mysql_slow
      service: mysql
    fields_under_root: true

  # Redis日志
  - type: log
    paths:
      - '/var/log/redis/redis.log'
    fields:
      log_type: redis
      service: redis
    fields_under_root: true

  # Nginx访问日志
  - type: log
    paths:
      - '/var/log/nginx/access.log'
    fields:
      log_type: nginx_access
      service: nginx
    fields_under_root: true

  # Kong访问日志
  - type: log
    paths:
      - '/var/log/kong/access.log'
    fields:
      log_type: kong_access
      service: kong
    fields_under_root: true

# 输出到Logstash
output.logstash:
  hosts: ["logstash.internal:5044"]
  ssl.enabled: true
  ssl.certificate_authorities: ["/etc/filebeat/ca.crt"]

# 处理器
processors:
  - add_host_metadata:
      when.not.contains.tags: forwarded
  - add_cloud_metadata: ~
```

### 3.2 Logstash管道配置

```ruby
# logstash.conf
input {
  beats {
    port => 5044
  }
}

filter {
  # K8s日志解析
  if [kubernetes] {
    grok {
      match => { "message" => "%{TIMESTAMP_ISO8601:timestamp} %{LOGLEVEL:level} %{GREEDYDATA:log_message}" }
    }
    mutate {
      add_field => { "source" => "kubernetes" }
    }
  }

  # MySQL慢查询解析
  if [log_type] == "mysql_slow" {
    grok {
      match => { "message" => "# Query_time: %{NUMBER:query_time} %{GREEDYDATA:query}" }
    }
    mutate {
      add_field => { "source" => "mysql" }
    }
  }

  # Nginx访问日志解析
  if [log_type] == "nginx_access" {
    grok {
      match => { "message" => "%{IPORHOST:remote_ip} - %{DATA:user} \[%{HTTPDATE:access_time}\] \"%{WORD:method} %{DATA:request} HTTP/%{NUMBER:http_version}\" %{NUMBER:status} %{NUMBER:bytes_sent} \"%{DATA:referrer}\" \"%{DATA:user_agent}\"" }
    }
    mutate {
      add_field => { "source" => "nginx" }
    }
  }
}

output {
  elasticsearch {
    hosts => ["elasticsearch.internal:9200"]
    index => "%{[source]}-%{+YYYY.MM.dd}"
  }
}
```

---

## 四、告警联动设计

### 4.1 Alertmanager配置

```yaml
# alertmanager.yml
global:
  resolve_timeout: 5m
  slack_api_url: 'https://hooks.slack.com/xxx'

route:
  group_by: ['alertname', 'severity']
  group_wait: 10s
  group_interval: 10s
  repeat_interval: 12h
  receiver: 'web.hook'

  routes:
    # 严重告警 → PagerDuty
    - match:
        severity: critical
      receiver: 'pagerduty-critical'

    # 警告告警 → 钉钉/企微
    - match:
        severity: warning
      receiver: 'webhook-dingtalk'

    # 信息告警 → 邮件
    - match:
        severity: info
      receiver: 'email-info'

receivers:
  # PagerDuty集成
  - name: 'pagerduty-critical'
    pagerduty_configs:
      - service_key: '<pagerduty-service-key>'
        description: '{{ .GroupLabels.alertname }}'
        details:
          severity: '{{ .GroupLabels.severity }}'
          instance: '{{ .CommonLabels.instance }}'
          summary: '{{ .CommonAnnotations.summary }}'

  # 钉钉/企微Webhook
  - name: 'webhook-dingtalk'
    webhook_configs:
      - url: 'http://dingtalk-webhook:8060/dingtalk/ops/send'
        send_resolved: true

  # 邮件
  - name: 'email-info'
    email_configs:
      - to: 'ops@company.com'
        from: 'alertmanager@company.com'
        smarthost: 'smtp.company.com:587'
        auth_username: 'alertmanager@company.com'
        auth_password: '<email-password>'
        send_resolved: true

  # 默认Webhook
  - name: 'web.hook'
    webhook_configs:
      - url: 'http://webhook-receiver:8080/alert'
        send_resolved: true

inhibit_rules:
  # critical告警抑制warning告警
  - source_match:
      severity: 'critical'
    target_match:
      severity: 'warning'
    equal: ['alertname', 'instance']
```

### 4.2 告警规则矩阵

| 组件 | 告警规则 | 严重级别 | 通知方式 |
|------|----------|----------|----------|
| Node | CPU>90%持续5分钟 | warning | 钉钉 |
| Node | 内存>95% | critical | PagerDuty |
| Node | 磁盘>85% | warning | 钉钉 |
| MySQL | 连接数>80% | warning | 钉钉 |
| MySQL | 主从延迟>10s | critical | PagerDuty |
| MySQL | 复制中断 | critical | PagerDuty |
| Redis | 内存>80% | warning | 钉钉 |
| Redis | 连接数>10000 | warning | 钉钉 |
| Redis | 集群节点故障 | critical | PagerDuty |
| Nginx | 5xx错误率>1% | critical | PagerDuty |
| Nginx | 请求延迟>2s | warning | 钉钉 |
| Kong | 路由失败率>5% | critical | PagerDuty |
| K8s | Pod重启>3次/小时 | warning | 钉钉 |
| K8s | 节点NotReady | critical | PagerDuty |
| etcd | 延迟>100ms | warning | 钉钉 |
| etcd | 集群成员故障 | critical | PagerDuty |

---

## 五、安全统一设计

### 5.1 CI/CD安全扫描流程

```
代码提交 → SonarQube代码扫描 → Trivy镜像扫描 → Harbor存储 → ArgoCD部署
    │           │                    │              │            │
    │           ▼                    ▼              │            │
    │      代码质量门禁          漏洞扫描门禁       │            │
    │      (覆盖率>80%)        (无HIGH/CRITICAL)   │            │
    │           │                    │              │            │
    │           ▼                    ▼              │            │
    │      阻断构建              阻断推送           │            │
    │                                              │            │
    │                                              ▼            │
    │                                     镜像签名(Cosign)      │
    │                                              │            │
    │                                              ▼            │
    │                                     Admission Controller  │
    │                                     (验证镜像签名)         │
```

### 5.2 Admission Controller配置

```yaml
# image-policy-webhook.yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingWebhookConfiguration
metadata:
  name: image-policy-webhook
webhooks:
  - name: image-policy.company.com
    clientConfig:
      service:
        name: image-policy-webhook
        namespace: kube-system
        path: "/validate"
      caBundle: <base64-ca-cert>
    rules:
      - operations: ["CREATE"]
        apiGroups: [""]
        apiVersions: ["v1"]
        resources: ["pods"]
    failurePolicy: Fail
    sideEffects: None
    admissionReviewVersions: ["v1"]
```

---

## 六、CI/CD到K8s数据流

### 6.1 完整流水线

```groovy
// Jenkinsfile
pipeline {
    agent any
    
    environment {
        HARBOR_REGISTRY = 'harbor.internal.com'
        HARBOR_PROJECT = 'production'
        ARGOCD_SERVER = 'argocd.internal.com'
    }
    
    stages {
        stage('代码扫描') {
            steps {
                sh 'sonar-scanner -Dsonar.projectKey=${JOB_NAME}'
            }
        }
        
        stage('构建镜像') {
            steps {
                sh 'docker build -t ${HARBOR_REGISTRY}/${HARBOR_PROJECT}/${JOB_NAME}:${BUILD_NUMBER} .'
            }
        }
        
        stage('Trivy扫描') {
            steps {
                sh 'trivy image --severity HIGH,CRITICAL --exit-code 1 ${HARBOR_REGISTRY}/${HARBOR_PROJECT}/${JOB_NAME}:${BUILD_NUMBER}'
            }
        }
        
        stage('推送镜像') {
            steps {
                withCredentials([usernamePassword(credentialsId: 'harbor-credentials', usernameVariable: 'HARBOR_USER', passwordVariable: 'HARBOR_PASS')]) {
                    sh 'echo ${HARBOR_PASS} | docker login ${HARBOR_REGISTRY} -u ${HARBOR_USER} --password-stdin'
                    sh 'docker push ${HARBOR_REGISTRY}/${HARBOR_PROJECT}/${JOB_NAME}:${BUILD_NUMBER}'
                }
            }
        }
        
        stage('更新GitOps仓库') {
            steps {
                withCredentials([usernamePassword(credentialsId: 'git-credentials', usernameVariable: 'GIT_USER', passwordVariable: 'GIT_PASS')]) {
                    sh '''
                        git clone https://${GIT_USER}:${GIT_PASS}@git.internal.com/argocd-apps.git
                        cd argocd-apps
                        sed -i "s|image:.*|image: ${HARBOR_REGISTRY}/${HARBOR_PROJECT}/${JOB_NAME}:${BUILD_NUMBER}|" apps/${JOB_NAME}/values.yaml
                        git add .
                        git commit -m "Update ${JOB_NAME} to ${BUILD_NUMBER}"
                        git push
                    '''
                }
            }
        }
    }
}
```

### 6.2 凭证管理

```yaml
# k8s-secrets.yaml
apiVersion: v1
kind: Secret
metadata:
  name: harbor-credentials
  namespace: argocd
type: kubernetes.io/dockerconfigjson
data:
  .dockerconfigjson: <base64-docker-config>

---
apiVersion: v1
kind: Secret
metadata:
  name: git-credentials
  namespace: argocd
type: Opaque
data:
  username: <base64-username>
  password: <base64-password>

---
apiVersion: v1
kind: Secret
metadata:
  name: mysql-credentials
  namespace: production
type: Opaque
data:
  mysql-host: <base64-mysql-host>
  mysql-user: <base64-mysql-user>
  mysql-password: <base64-mysql-password>
  mysql-database: <base64-mysql-database>
```

---

## 七、K8s到数据库连接

### 7.1 微服务数据库连接配置

```yaml
# deployment-with-db.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: user-service
  namespace: production
spec:
  replicas: 3
  selector:
    matchLabels:
      app: user-service
  template:
    metadata:
      labels:
        app: user-service
    spec:
      containers:
        - name: user-service
          image: harbor.internal.com/production/user-service:v1.0.0
          env:
            # MySQL连接（从Secret读取）
            - name: MYSQL_HOST
              valueFrom:
                secretKeyRef:
                  name: mysql-credentials
                  key: mysql-host
            - name: MYSQL_USER
              valueFrom:
                secretKeyRef:
                  name: mysql-credentials
                  key: mysql-user
            - name: MYSQL_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: mysql-credentials
                  key: mysql-password
            - name: MYSQL_DATABASE
              valueFrom:
                secretKeyRef:
                  name: mysql-credentials
                  key: mysql-database
            # Redis连接（从ConfigMap读取）
            - name: REDIS_HOST
              valueFrom:
                configMapKeyRef:
                  name: redis-config
                  key: redis-host
            - name: REDIS_PORT
              valueFrom:
                configMapKeyRef:
                  name: redis-config
                  key: redis-port
          ports:
            - containerPort: 8080
          resources:
            requests:
              cpu: 250m
              memory: 512Mi
            limits:
              cpu: 1000m
              memory: 1Gi

---
# redis-config.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: redis-config
  namespace: production
data:
  redis-host: "redis-cluster.internal"
  redis-port: "6379"
```

---

## 八、网关到微服务路由

### 8.1 Kong路由配置

```yaml
# kong-routes.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: user-service-ingress
  namespace: production
  annotations:
    konghq.com/protocols: "https"
    konghq.com/plugins: user-service-rate-limit,user-service-jwt
spec:
  ingressClassName: kong
  tls:
    - hosts:
        - api.company.com
      secretName: api-tls-secret
  rules:
    - host: api.company.com
      http:
        paths:
          - path: /api/v1/users
            pathType: Prefix
            backend:
              service:
                name: user-service
                port:
                  number: 8080

---
# kong-service.yaml
apiVersion: configuration.konghq.com/v1
kind: KongService
metadata:
  name: user-service
  namespace: production
spec:
  host: api.company.com
  port: 8080
  protocol: http
  connect_timeout: 5000
  read_timeout: 60000
  write_timeout: 60000
  retries: 3

---
# kong-upstream.yaml
apiVersion: configuration.konghq.com/v1
kind: KongUpstream
metadata:
  name: user-service-upstream
  namespace: production
spec:
  name: user-service
  algorithm: round-robin
  hash_on: none
  healthchecks:
    active:
      http_path: /health
      http_status_codes: [200]
      interval: 10
      timeout: 5
      unhealthy_threshold: 3
      healthy_threshold: 2
    passive:
      http_status_codes: [500, 502, 503]
      unhealthy_threshold: 3
      healthy_threshold: 2
```

---

## 九、灾备设计

### 9.1 RPO/RTO目标

| 组件 | RPO(数据丢失) | RTO(恢复时间) | 备份策略 | 故障转移方式 |
|------|---------------|---------------|----------|--------------|
| MySQL | < 1秒 | < 5分钟 | MGR强一致性 + sync_binlog | MGR自动failover |
| Redis | < 1秒 | < 30秒 | AOF everysec + Cluster复制 | Sentinel自动故障转移 |
| etcd | < 1小时 | < 10分钟 | 每6小时快照 + 跨区域备份 | 手动恢复 |
| K8s | 0 | < 5分钟 | etcd备份 + GitOps配置 | 重建集群 |
| Harbor | < 1小时 | < 30分钟 | S3跨区域复制 | DNS切换 |
| ELK | < 1小时 | < 30分钟 | 快照 + 跨集群复制 | 重建集群 |

### 9.2 数据一致性风险

| 风险 | 影响 | 缓解措施 |
|------|------|----------|
| MySQL MGR跨机房延迟 | 写入延迟增加 | 使用同城双活，延迟<10ms |
| Redis Cluster异步复制 | 故障时丢失少量数据 | 使用AOF everysec，RPO<1秒 |
| etcd跨区域备份延迟 | 恢复时数据丢失 | 每6小时备份，RPO<6小时 |
| Harbor镜像复制延迟 | 镜像版本不一致 | 使用事件驱动复制 |

### 9.3 Operator自动故障转移

```yaml
# mysql-operator.yaml
apiVersion: mysql.presslabs.org/v1alpha1
kind: MySQLCluster
metadata:
  name: mysql-cluster
  namespace: database
spec:
  replicas: 3
  secretName: mysql-secret
  mysqlVersion: "8.0"
  # 自动故障转移配置
  mysqlConf:
    max_connections: "1000"
    innodb_buffer_pool_size: "4G"
    sync_binlog: "1"
    innodb_flush_log_at_trx_commit: "1"
  # 备份配置
  backupSchedule: "0 2 * * *"
  backupRemoteStorage:
    s3:
      bucket: mysql-backups
      region: cn-beijing
      endpoint: https://s3.cn-north-1.amazonaws.com.cn

---
# redis-operator.yaml
apiVersion: databases.spotahome.com/v1
kind: RedisFailover
metadata:
  name: redis-cluster
  namespace: database
spec:
  sentinel:
    replicas: 3
    resources:
      requests:
        cpu: 100m
        memory: 128Mi
  redis:
    replicas: 3
    resources:
      requests:
        cpu: 500m
        memory: 1Gi
    storage:
      persistentVolumeClaim:
        claimName: redis-data
  # 自动故障转移配置
  customConfig:
    redis-config: |
      maxmemory 1gb
      maxmemory-policy allkeys-lru
      appendonly yes
      appendfsync everysec
```

---

## 十、项目间接口定义

### 10.1 项目依赖关系

```
01-容器云平台 ─────────────────────────────────────────────────┐
    │                                                          │
    ├──▶ 02-CI/CD全链路 ──▶ 01-容器云平台(镜像仓库)           │
    │                                                          │
    ├──▶ 03-监控告警体系 ◀── 01-容器云平台(Prometheus)         │
    │                                                          │
    ├──▶ 04-ELK日志平台 ◀── 01-容器云平台(Filebeat)           │
    │                                                          │
    ├──▶ 05-MySQL高可用 ◀── 01-容器云平台(数据库服务)         │
    │                                                          │
    ├──▶ 06-Redis集群 ◀── 01-容器云平台(缓存服务)             │
    │                                                          │
    ├──▶ 07-Nginx高可用 ◀── 01-容器云平台(反向代理)           │
    │                                                          │
    ├──▶ 08-自动化运维 ◀── 所有项目(Ansible/Terraform)        │
    │                                                          │
    ├──▶ 09-微服务网关 ◀── 01-容器云平台(Kong部署)            │
    │                                                          │
    └──▶ 10-安全加固 ◀── 所有项目(安全策略)                   │
```

### 10.2 接口契约

| 接口 | 提供方 | 消费方 | 协议 | 端口 |
|------|--------|--------|------|------|
| MySQL | 05-MySQL高可用 | 01-K8s微服务 | TCP | 3306 |
| Redis | 06-Redis集群 | 01-K8s微服务 | TCP | 6379 |
| Prometheus | 03-监控告警 | 所有Exporter | HTTP | 9090 |
| Elasticsearch | 04-ELK日志 | Filebeat | HTTP | 9200 |
| Harbor | 01-容器云平台 | Jenkins/ArgoCD | HTTPS | 443 |
| Kong | 09-微服务网关 | 外部客户端 | HTTPS | 443 |

---

> **文档维护**：本文档应随项目变更同步更新，每次架构调整需review本文档。
