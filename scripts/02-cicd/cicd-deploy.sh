#!/bin/bash
# CI/CD流水线完整部署脚本
# 部署Jenkins + SonarQube + ArgoCD到K8s集群
# 依赖: kubectl, K8s集群已就绪
# 前置: Harbor镜像仓库已部署(node-init.sh), K8s集群已初始化
set -euo pipefail
umask 077

NAMESPACE="${NAMESPACE:-cicd}"
REGISTRY="${REGISTRY:-harbor.example.com}"

echo "=== CI/CD完整部署 ==="

# 1. 创建命名空间
kubectl create namespace ${NAMESPACE} --dry-run=client -o yaml | kubectl apply -f -
# 1.1 检查节点sysctl设置(SonarQube需要vm.max_map_count>=524288)
echo "检查节点vm.max_map_count..."
for node in $(kubectl get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null); do
  current=$(ssh -o ConnectTimeout=3 root@${node} "sysctl -n vm.max_map_count" 2>/dev/null || echo "0")
  if [ "${current:-0}" -lt 524288 ]; then
    echo "  警告: 节点 ${node} vm.max_map_count=${current}，SonarQube要求>=524288"
    echo "  请在节点上执行: echo 'vm.max_map_count=524288' >> /etc/sysctl.d/99-sonarqube.conf && sysctl -p"
  fi
done

# 2. Jenkins PVC
kubectl apply -n ${NAMESPACE} -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: jenkins-pvc
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 50Gi
EOF

# 3. Jenkins Service
kubectl apply -n ${NAMESPACE} -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: jenkins
spec:
  type: LoadBalancer
  ports:
    - name: http
      port: 8080
      targetPort: 8080
    - name: agent
      port: 50000
      targetPort: 50000
  selector:
    app: jenkins
EOF

# 4. Jenkins RBAC (ServiceAccount/Role/RoleBinding)
kubectl apply -n ${NAMESPACE} -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: jenkins
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: jenkins-role
  namespace: ${NAMESPACE}
rules:
  - apiGroups: [""]
    resources: ["pods", "services", "configmaps"]
    verbs: ["get", "list", "watch", "create", "update"]
  - apiGroups: ["apps"]
    resources: ["deployments", "replicasets", "statefulsets"]
    verbs: ["get", "list", "watch", "create", "update"]
  - apiGroups: ["networking.k8s.io"]
    resources: ["ingresses"]
    verbs: ["get", "list", "watch", "create", "update"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: jenkins
  namespace: ${NAMESPACE}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: jenkins-role
subjects:
  - kind: ServiceAccount
    name: jenkins
    namespace: ${NAMESPACE}
EOF

# 5. Jenkins Deployment
kubectl apply -n ${NAMESPACE} -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: jenkins
spec:
  replicas: 1
  selector:
    matchLabels:
      app: jenkins
  template:
    metadata:
      labels:
        app: jenkins
    spec:
      serviceAccountName: jenkins
      containers:
        - name: jenkins
          image: jenkins/jenkins:lts-jdk17
          ports:
            - containerPort: 8080
            - containerPort: 50000
          volumeMounts:
            - name: jenkins-data
              mountPath: /var/jenkins_home
          resources:
            requests:
              cpu: 500m
              memory: 1Gi
            limits:
              cpu: 2
              memory: 4Gi
      volumes:
        - name: jenkins-data
          persistentVolumeClaim:
            claimName: jenkins-pvc
EOF

# 6. SonarQube PostgreSQL(必须先部署)
echo "部署SonarQube PostgreSQL..."
SONAR_DB_PASS="${SONAR_DB_PASS:?请设置SONAR_DB_PASS}"
kubectl apply -n ${NAMESPACE} -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: sonar-db-secret
type: Opaque
stringData:
  POSTGRES_PASSWORD: "${SONAR_DB_PASS}"
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: sonar-db
spec:
  replicas: 1
  serviceName: sonar-db
  selector:
    matchLabels:
      app: sonar-db
  template:
    metadata:
      labels:
        app: sonar-db
    spec:
      containers:
        - name: postgresql
          image: postgres:14-alpine
          env:
            - name: POSTGRES_DB
              value: sonarqube
            - name: POSTGRES_USER
              value: sonar
            - name: POSTGRES_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: sonar-db-secret
                  key: POSTGRES_PASSWORD
          ports:
            - containerPort: 5432
          volumeMounts:
            - name: pg-data
              mountPath: /var/lib/postgresql/data
          resources:
            requests:
              cpu: 250m
              memory: 512Mi
            limits:
              cpu: 1000m
              memory: 2Gi
  volumeClaimTemplates:
    - metadata:
        name: pg-data
      spec:
        accessModes: ["ReadWriteOnce"]
        resources:
          requests:
            storage: 20Gi
---
apiVersion: v1
kind: Service
metadata:
  name: sonar-db
spec:
  type: ClusterIP
  ports:
    - port: 5432
      targetPort: 5432
  selector:
    app: sonar-db
EOF

# 7. SonarQube
echo "部署SonarQube..."
kubectl apply -n ${NAMESPACE} -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: sonarqube
spec:
  replicas: 1
  selector:
    matchLabels:
      app: sonarqube
  template:
    metadata:
      labels:
        app: sonarqube
    spec:
      containers:
        - name: sonarqube
          image: sonarqube:10-community
          ports:
            - containerPort: 9000
          env:
            - name: SONAR_JDBC_URL
              value: "jdbc:postgresql://sonar-db:5432/sonarqube"
            - name: SONAR_JDBC_USERNAME
              value: "sonar"
            - name: SONAR_JDBC_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: sonar-db-secret
                  key: POSTGRES_PASSWORD
          volumeMounts:
            - name: sonar-data
              mountPath: /opt/sonarqube/data
      volumes:
        - name: sonar-data
          persistentVolumeClaim:
            claimName: sonarqube-pvc
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: sonarqube-pvc
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 20Gi
---
apiVersion: v1
kind: Service
metadata:
  name: sonarqube
spec:
  type: ClusterIP
  ports:
    - port: 9000
      targetPort: 9000
  selector:
    app: sonarqube
EOF

# 8. ArgoCD
echo "部署ArgoCD..."
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

echo "✅ CI/CD完整部署完成"
echo "  Jenkins:   http://<EXTERNAL-IP>:8080"
echo "  SonarQube: http://<EXTERNAL-IP>:9000"
echo "  ArgoCD:    kubectl -n argocd get svc argocd-server"
