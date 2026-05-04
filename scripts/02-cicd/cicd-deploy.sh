#!/bin/bash
# CI/CD流水线完整部署脚本
# 部署Jenkins + SonarQube + ArgoCD到K8s集群
set -euo pipefail
umask 077

NAMESPACE="${NAMESPACE:-cicd}"
REGISTRY="${REGISTRY:-harbor.example.com}"

echo "=== CI/CD完整部署 ==="

# 1. 创建命名空间
kubectl create namespace ${NAMESPACE} --dry-run=client -o yaml | kubectl apply -f -

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

# 4. Jenkins Deployment
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

# 5. Jenkins RBAC
kubectl apply -n ${NAMESPACE} -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: jenkins
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: jenkins-role
rules:
  - apiGroups: [""]
    resources: ["pods", "services", "configmaps", "secrets"]
    verbs: ["get", "list", "watch", "create", "update", "delete"]
  - apiGroups: ["apps"]
    resources: ["deployments", "replicasets", "statefulsets"]
    verbs: ["get", "list", "watch", "create", "update", "delete"]
  - apiGroups: ["networking.k8s.io"]
    resources: ["ingresses"]
    verbs: ["get", "list", "watch", "create", "update", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: jenkins
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: jenkins-role
subjects:
  - kind: ServiceAccount
    name: jenkins
    namespace: ${NAMESPACE}
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
      initContainers:
        - name: sysctl
          image: busybox
          command: ["sysctl", "-w", "vm.max_map_count=524288"]
          securityContext:
            privileged: true
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
          emptyDir: {}
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
