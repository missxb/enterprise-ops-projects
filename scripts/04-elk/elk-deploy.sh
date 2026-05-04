#!/bin/bash
# ELK生产级部署(Elasticsearch集群+Logstash+Filebeat+Kibana)
set -euo pipefail
umask 077

NAMESPACE="${NAMESPACE:-logging}"
ES_VERSION="${ES_VERSION:-8.11.3}"
ES_PASSWORD="${ES_PASSWORD:?请设置ES_PASSWORD}"

echo "=== ELK生产级部署 ==="

# Step 1: 创建命名空间
echo ">>> Step 1: 创建命名空间"
kubectl create namespace ${NAMESPACE} --dry-run=client -o yaml | kubectl apply -f -

# Step 2: 创建ES密码Secret
echo ">>> Step 2: 创建ES密码Secret"
kubectl apply -n ${NAMESPACE} -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: es-secret
type: Opaque
stringData:
  password: "${ES_PASSWORD}"
EOF

# Step 3: 部署Elasticsearch集群(3节点)
echo ">>> Step 3: 部署Elasticsearch集群"
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
  volumeClaimTemplates:
    - metadata:
        name: es-data
      spec:
        accessModes: ["ReadWriteOnce"]
        resources:
          requests:
            storage: 500Gi
EOF

# Step 4: 部署Logstash
echo ">>> Step 4: 部署Logstash"
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

# Step 5: 部署Filebeat(DaemonSet)
echo ">>> Step 5: 部署Filebeat"
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
            - name: containers
              mountPath: /var/lib/docker/containers
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
        - name: containers
          hostPath:
            path: /var/lib/docker/containers
        - name: filebeat-config
          configMap:
            name: filebeat-config
EOF

# Step 6: 部署Kibana
echo ">>> Step 6: 部署Kibana"
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
              value: "http://elasticsearch-0.elasticsearch:9200"
            - name: ELASTICSEARCH_USERNAME
              value: "elastic"
            - name: ELASTICSEARCH_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: es-secret
                  key: password
          ports:
            - containerPort: 5601
          resources:
            requests:
              cpu: 500m
              memory: 1Gi
            limits:
              cpu: 2000m
              memory: 4Gi
EOF

echo ""
echo "=== ELK部署完成 ==="
echo "  Elasticsearch: http://elasticsearch:9200"
echo "  Kibana: http://kibana:5601"
