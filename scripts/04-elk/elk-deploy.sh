#!/bin/bash
# ELK生产级部署(Elasticsearch集群+Logstash+Filebeat+Kibana)
# 依赖: kubectl, helm
# 前置: K8s集群已就绪, 至少3个Worker节点(ES需要), 节点vm.max_map_count>=524288
set -euo pipefail
umask 077

NAMESPACE="${NAMESPACE:-logging}"
ES_VERSION="${ES_VERSION:-8.11.3}"
ES_PASSWORD="${ES_PASSWORD:?请设置ES_PASSWORD}"

echo "=== ELK生产级部署 ==="

# Step 1: 创建命名空间
echo ">>> Step 1: 创建命名空间"
kubectl create namespace ${NAMESPACE} --dry-run=client -o yaml | kubectl apply -f -
# Step 2: 生成ES TLS证书
echo ">>> Step 2: 生成ES TLS证书"
CERT_DIR=$(mktemp -d)
trap 'rm -rf "${CERT_DIR}"' EXIT

# 生成CA
openssl genrsa -out "${CERT_DIR}/ca.key" 2048
openssl req -x509 -new -nodes -key "${CERT_DIR}/ca.key" -sha256 -days 3650 \
  -out "${CERT_DIR}/ca.crt" -subj "/CN=ELK-CA"

# 生成Transport证书(节点间通信)
openssl genrsa -out "${CERT_DIR}/transport.key" 2048
openssl req -new -key "${CERT_DIR}/transport.key" \
  -out "${CERT_DIR}/transport.csr" -subj "/CN=elasticsearch-transport"
openssl x509 -req -in "${CERT_DIR}/transport.csr" -CA "${CERT_DIR}/ca.crt" -CAkey "${CERT_DIR}/ca.key" \
  -CAcreateserial -out "${CERT_DIR}/transport.crt" -days 3650 -sha256
cat "${CERT_DIR}/transport.key" "${CERT_DIR}/transport.crt" | openssl pkcs12 -export \
  -out "${CERT_DIR}/transport.p12" -passout pass:changeit

# 生成HTTP证书(客户端访问)
openssl genrsa -out "${CERT_DIR}/http.key" 2048
openssl req -new -key "${CERT_DIR}/http.key" \
  -out "${CERT_DIR}/http.csr" -subj "/CN=elasticsearch-http"
openssl x509 -req -in "${CERT_DIR}/http.csr" -CA "${CERT_DIR}/ca.crt" -CAkey "${CERT_DIR}/ca.key" \
  -CAcreateserial -out "${CERT_DIR}/http.crt" -days 3650 -sha256
cat "${CERT_DIR}/http.key" "${CERT_DIR}/http.crt" | openssl pkcs12 -export \
  -out "${CERT_DIR}/http.p12" -passout pass:changeit

# 创建K8s Secret存储证书
kubectl create secret generic es-certs -n ${NAMESPACE} \
  --from-file=ca.crt="${CERT_DIR}/ca.crt" \
  --from-file=transport.p12="${CERT_DIR}/transport.p12" \
  --from-file=http.p12="${CERT_DIR}/http.p12" \
  --dry-run=client -o yaml | kubectl apply -f -

# Step 3: 创建ES密码Secret
echo ">>> Step 3: 创建ES密码Secret"
kubectl apply -n ${NAMESPACE} -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: es-secret
type: Opaque
stringData:
  password: "${ES_PASSWORD}"
EOF

# Step 4: 部署Elasticsearch集群(3节点)
echo ">>> Step 4: 部署Elasticsearch集群"
cat << EOF | kubectl apply -f -
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: elasticsearch
  namespace: logging
spec:
  replicas: 3
  serviceName: elasticsearch
  selector:
    matchLabels:
      app: elasticsearch
  template:
    metadata:
      labels:
        app: elasticsearch
    spec:
      initContainers:
        - name: sysctl
          image: busybox
          command: ['sysctl', '-w', 'vm.max_map_count=262144']
          securityContext:
            privileged: true
      containers:
        - name: elasticsearch
          image: elasticsearch:${ES_VERSION}
          env:
            - name: cluster.name
              value: "elk-cluster"
            - name: node.name
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
            - name: discovery.seed_hosts
              value: "elasticsearch-0.elasticsearch,elasticsearch-1.elasticsearch,elasticsearch-2.elasticsearch"
            - name: cluster.initial_master_nodes
              value: "elasticsearch-0,elasticsearch-1,elasticsearch-2"
            - name: ES_JAVA_OPTS
              value: "-Xms16g -Xmx16g"
            - name: xpack.security.enabled
              value: "true"
            - name: xpack.security.transport.ssl.enabled
              value: "true"
            - name: xpack.security.http.ssl.enabled
              value: "true"
            - name: ELASTIC_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: es-secret
                  key: password
          ports:
            - containerPort: 9200
            - containerPort: 9300
          resources:
            requests:
              cpu: 1000m
              memory: 32Gi
            limits:
              cpu: 4000m
              memory: 64Gi
          volumeMounts:
            - name: es-data
              mountPath: /usr/share/elasticsearch/data
            - name: es-certs
              mountPath: /usr/share/elasticsearch/config/certs
              readOnly: true
  volumes:
    - name: es-certs
      secret:
        secretName: es-certs
        defaultMode: 0400
  volumeClaimTemplates:
    - metadata:
        name: es-data
      spec:
        accessModes: ["ReadWriteOnce"]
        resources:
          requests:
            storage: 500Gi
EOF

# Step 5: 部署Logstash
echo ">>> Step 5: 部署Logstash"
cat << EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: logstash
  namespace: logging
spec:
  replicas: 2
  selector:
    matchLabels:
      app: logstash
  template:
    metadata:
      labels:
        app: logstash
    spec:
      containers:
        - name: logstash
          image: logstash:${ES_VERSION}
          volumeMounts:
            - name: logstash-config
              mountPath: /usr/share/logstash/pipeline
          resources:
            requests:
              cpu: 500m
              memory: 2Gi
            limits:
              cpu: 2000m
              memory: 4Gi
      volumes:
        - name: logstash-config
          configMap:
            name: logstash-config
EOF

# Step 6: 部署Filebeat(DaemonSet)
echo ">>> Step 6: 部署Filebeat"
cat << EOF | kubectl apply -f -
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
      containers:
        - name: filebeat
          image: elastic/filebeat:${ES_VERSION}
          volumeMounts:
            - name: varlog
              mountPath: /var/log
              readOnly: true
            - name: varlogpods
              mountPath: /var/log/pods
              readOnly: true
            - name: filebeat-config
              mountPath: /usr/share/filebeat/filebeat.yml
              subPath: filebeat.yml
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              cpu: 500m
              memory: 512Mi
      volumes:
        - name: varlog
          hostPath:
            path: /var/log
        - name: varlogpods
          hostPath:
            path: /var/log/pods
        - name: filebeat-config
          configMap:
            name: filebeat-config
EOF

# Step 7: 部署Kibana
echo ">>> Step 7: 部署Kibana"
cat << EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kibana
  namespace: logging
spec:
  replicas: 1
  selector:
    matchLabels:
      app: kibana
  template:
    metadata:
      labels:
        app: kibana
    spec:
      containers:
        - name: kibana
          image: kibana:${ES_VERSION}
          env:
            - name: ELASTICSEARCH_HOSTS
              value: "https://elasticsearch-0.elasticsearch:9200"
            - name: ELASTICSEARCH_USERNAME
              value: "elastic"
            - name: ELASTICSEARCH_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: es-secret
                  key: password
            - name: ELASTICSEARCH_SSL_CERTIFICATEAUTHORITIES
              value: "/usr/share/kibana/config/certs/ca.crt"
          ports:
            - containerPort: 5601
          volumeMounts:
            - name: es-certs
              mountPath: /usr/share/kibana/config/certs
              readOnly: true
          resources:
            requests:
              cpu: 500m
              memory: 1Gi
            limits:
              cpu: 2000m
              memory: 4Gi
      volumes:
        - name: es-certs
          secret:
            secretName: es-certs
            defaultMode: 0400
EOF

echo ""
echo "=== ELK部署完成 ==="
echo "  Elasticsearch: http://elasticsearch:9200"
echo "  Kibana: http://kibana:5601"
