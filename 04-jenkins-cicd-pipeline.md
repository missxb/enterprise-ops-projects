# 企业级项目04: Jenkins CI/CD 完整流水线

## 📋 项目概述

企业级CI/CD完整方案，包含代码构建、镜像推送、自动测试、Kubernetes部署、回滚策略。

**技术栈**: Jenkins + Docker + Kubernetes + Harbor + SonarQube + Trivy + ArgoCD

---

## 🏗️ 架构图

```
┌─────────────────────────────────────────────────────────────────┐
│                    CI/CD 流水线架构                               │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │                    CI 阶段 (构建)                         │   │
│  │                                                          │   │
│  │  ┌─────────┐    ┌──────────┐    ┌──────────┐           │   │
│  │  │  Git    │───▶│ Jenkins  │───▶│ SonarQube│           │   │
│  │  │  Push   │    │ Pipeline │    │ 代码扫描  │           │   │
│  │  └─────────┘    └────┬─────┘    └──────────┘           │   │
│  │                      │                                  │   │
│  │                 ┌────▼─────┐                            │   │
│  │                 │  Docker  │                            │   │
│  │                 │  Build   │                            │   │
│  │                 └────┬─────┘                            │   │
│  │                      │                                  │   │
│  │              ┌───────▼───────┐                          │   │
│  │              │    Trivy      │                          │   │
│  │              │  安全扫描     │                          │   │
│  │              └───────┬───────┘                          │   │
│  │                      │                                  │   │
│  │              ┌───────▼───────┐                          │   │
│  │              │    Harbor     │                          │   │
│  │              │  镜像仓库     │                          │   │
│  │              └───────────────┘                          │   │
│  └──────────────────────────────────────────────────────────┘   │
│                              │                                  │
│                              ▼                                  │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │                    CD 阶段 (部署)                         │   │
│  │                                                          │   │
│  │  ┌──────────┐    ┌──────────┐    ┌──────────┐          │   │
│  │  │  ArgoCD  │───▶│Kubernetes│───▶│  生产环境 │          │   │
│  │  │  GitOps  │    │  Cluster │    │  :80/443 │          │   │
│  │  └──────────┘    └──────────┘    └──────────┘          │   │
│  │                                                          │   │
│  │  ┌──────────────────────────────────────────────────┐   │   │
│  │  │  部署策略: Rolling / Blue-Green / Canary          │   │   │
│  │  │  自动回滚: 失败自动回滚到上一版本                    │   │   │
│  │  │  通知: 钉钉/企业微信/邮件                           │   │   │
│  │  └──────────────────────────────────────────────────┘   │   │
│  └──────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

---

## 🚀 部署方案

### 一键部署CI/CD环境

```bash
# docker-compose.yml
version: '3.8'

services:
  # ========== Jenkins ==========
  jenkins:
    image: jenkins/jenkins:lts
    container_name: jenkins
    restart: always
    ports:
      - "8080:8080"    # Web界面
      - "50000:50000"  # Agent通信
    volumes:
      - jenkins-data:/var/jenkins_home
      - /var/run/docker.sock:/var/run/docker.sock
    environment:
      - JAVA_OPTS=-Djenkins.install.runSetupWizard=false
      - JENKINS_OPTS=--prefix=/
    networks:
      - cicd
    deploy:
      resources:
        limits:
          cpus: '2.0'
          memory: 4G

  # ========== SonarQube ==========
  sonarqube:
    image: sonarqube:10-community
    container_name: sonarqube
    restart: always
    ports:
      - "9000:9000"
    volumes:
      - sonarqube-data:/opt/sonarqube/data
      - sonarqube-logs:/opt/sonarqube/logs
      - sonarqube-extensions:/opt/sonarqube/extensions
    environment:
      - SONAR_ES_BOOTSTRAP_CHECKS_DISABLE=true
    networks:
      - cicd

  # ========== Harbor (镜像仓库) ==========
  # Harbor推荐单独部署，这里用轻量级Registry替代
  registry:
    image: registry:2
    container_name: registry
    restart: always
    ports:
      - "5000:5000"
    volumes:
      - registry-data:/var/lib/registry
    environment:
      - REGISTRY_STORAGE_DELETE_ENABLED=true
    networks:
      - cicd

  # ========== ArgoCD ==========
  argocd-server:
    image: argoproj/argocd:v2.9.3
    container_name: argocd-server
    restart: always
    ports:
      - "8443:443"
      - "8080:8080"
    command:
      - argocd-server
      - --insecure
    volumes:
      - argocd-data:/home/argocd
    networks:
      - cicd

  # ========== Trivy (安全扫描) ==========
  trivy:
    image: aquasec/trivy:latest
    container_name: trivy
    volumes:
      - trivy-cache:/root/.cache/trivy
    networks:
      - cicd

  # ========== Nexus (制品仓库) ==========
  nexus:
    image: sonatype/nexus3:latest
    container_name: nexus
    restart: always
    ports:
      - "8081:8081"
    volumes:
      - nexus-data:/nexus-data
    networks:
      - cicd
    deploy:
      resources:
        limits:
          cpus: '2.0'
          memory: 4G

networks:
  cicd:
    driver: bridge

volumes:
  jenkins-data:
  sonarqube-data:
  sonarqube-logs:
  sonarqube-extensions:
  registry-data:
  argocd-data:
  trivy-cache:
  nexus-data:
```

---

## 📋 Jenkins Pipeline

### Jenkinsfile (完整CI/CD流水线)

```groovy
// ============================================
// 企业级 Jenkins Pipeline
// ============================================

pipeline {
    agent {
        kubernetes {
            yaml '''
                apiVersion: v1
                kind: Pod
                spec:
                  containers:
                  - name: jnlp
                    image: jenkins/inbound-agent:latest
                  - name: docker
                    image: docker:24-dind
                    securityContext:
                      privileged: true
                    env:
                    - name: DOCKER_TLS_CERTDIR
                      value: ""
                  - name: kubectl
                    image: bitnami/kubectl:latest
                    command: ['sleep']
                    args: ['infinity']
            '''
        }
    }

    // 环境变量
    environment {
        // 仓库配置
        REGISTRY = 'registry:5000'
        IMAGE_NAME = 'enterprise-app'
        IMAGE_TAG = "${env.BUILD_NUMBER}"
        
        // Kubernetes配置
        K8S_NAMESPACE = 'production'
        K8S_DEPLOYMENT = 'enterprise-app'
        
        // SonarQube
        SONAR_HOST = 'http://sonarqube:9000'
        
        // 通知
        DINGTALK_WEBHOOK = 'http://dingtalk-webhook:8060/dingtalk/ops/send'
    }

    // 触发器
    triggers {
        // Webhook触发 (Git Push)
        githubPush()
        
        // 定时构建 (每天凌晨2点)
        cron('0 2 * * *')
    }

    // 阶段
    stages {
        // ========== 阶段1: 代码检出 ==========
        stage('Checkout') {
            steps {
                echo "📥 代码检出..."
                checkout([
                    $class: 'GitSCM',
                    branches: [[name: '*/main']],
                    userRemoteConfigs: [[
                        url: 'https://github.com/your-org/your-app.git',
                        credentialsId: 'git-credentials'
                    ]]
                ])
                script {
                    env.GIT_COMMIT_SHORT = sh(
                        script: "git rev-parse --short HEAD",
                        returnStdout: true
                    ).trim()
                    env.GIT_COMMIT_MSG = sh(
                        script: "git log -1 --pretty=%B",
                        returnStdout: true
                    ).trim()
                }
                echo "当前提交: ${env.GIT_COMMIT_SHORT}"
                echo "提交信息: ${env.GIT_COMMIT_MSG}"
            }
        }

        // ========== 阶段2: 依赖安装和测试 ==========
        stage('Test') {
            parallel {
                stage('Unit Tests') {
                    steps {
                        echo "🧪 运行单元测试..."
                        sh '''
                            # Python项目示例
                            pip install -r requirements.txt
                            pytest tests/ --cov=app --cov-report=xml --junitxml=reports/junit.xml
                            
                            # Node.js项目示例
                            # npm ci
                            # npm test
                            
                            # Go项目示例
                            # go test ./... -v -coverprofile=coverage.out
                        '''
                    }
                    post {
                        always {
                            junit 'reports/junit.xml'
                            publishHTML([
                                reportDir: 'htmlcov',
                                reportFiles: 'index.html',
                                reportName: 'Coverage Report'
                            ])
                        }
                    }
                }

                stage('Code Quality') {
                    steps {
                        echo "🔍 代码质量扫描..."
                        withSonarQubeEnv('SonarQube') {
                            sh '''
                                sonar-scanner \
                                    -Dsonar.projectKey=enterprise-app \
                                    -Dsonar.sources=app \
                                    -Dsonar.tests=tests \
                                    -Dsonar.python.coverage.reportPaths=coverage.xml \
                                    -Dsonar.host.url=${SONAR_HOST}
                            '''
                        }
                    }
                }

                stage('Lint') {
                    steps {
                        echo "📝 代码规范检查..."
                        sh '''
                            # Python
                            flake8 app/ --max-line-length=120
                            black --check app/
                            mypy app/
                            
                            # 或者使用pre-commit
                            # pre-commit run --all-files
                        '''
                    }
                }
            }
        }

        // ========== 阶段3: 构建Docker镜像 ==========
        stage('Build Image') {
            steps {
                echo "🔨 构建Docker镜像..."
                script {
                    docker.build("${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}")
                    docker.build("${REGISTRY}/${IMAGE_NAME}:latest")
                }
            }
        }

        // ========== 阶段4: 安全扫描 ==========
        stage('Security Scan') {
            steps {
                echo "🔒 安全扫描..."
                sh '''
                    trivy image --exit-code 1 --severity HIGH,CRITICAL \
                        ${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}
                '''
            }
            post {
                failure {
                    echo "⚠️ 安全扫描发现高危漏洞！"
                    script {
                        notifyDingTalk("安全扫描失败", "warning")
                    }
                }
            }
        }

        // ========== 阶段5: 推送镜像 ==========
        stage('Push Image') {
            steps {
                echo "📤 推送镜像到仓库..."
                sh '''
                    docker push ${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}
                    docker push ${REGISTRY}/${IMAGE_NAME}:latest
                '''
            }
        }

        // ========== 阶段6: 部署到Staging ==========
        stage('Deploy to Staging') {
            steps {
                echo "🚀 部署到Staging环境..."
                sh '''
                    kubectl set image deployment/${K8S_DEPLOYMENT} \
                        ${IMAGE_NAME}=${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG} \
                        -n staging
                    
                    kubectl rollout status deployment/${K8S_DEPLOYMENT} \
                        -n staging --timeout=300s
                '''
            }
        }

        // ========== 阶段7: 集成测试 ==========
        stage('Integration Tests') {
            steps {
                echo "🧪 运行集成测试..."
                sh '''
                    # 等待应用就绪
                    sleep 30
                    
                    # 运行集成测试
                    pytest tests/integration/ \
                        --base-url=http://staging-app:8080 \
                        --junitxml=reports/integration.xml
                '''
            }
            post {
                always {
                    junit 'reports/integration.xml'
                }
            }
        }

        // ========== 阶段8: 审批部署到生产 ==========
        stage('Approval') {
            steps {
                echo "⏳ 等待部署审批..."
                script {
                    def deployApproval = input(
                        message: '是否部署到生产环境？',
                        ok: '确认部署',
                        submitter: 'admin,ops-team',
                        parameters: [
                            choice(
                                name: 'DEPLOY_STRATEGY',
                                choices: ['rolling', 'blue-green', 'canary'],
                                description: '选择部署策略'
                            ),
                            string(
                                name: 'REASON',
                                defaultValue: '',
                                description: '部署原因'
                            )
                        ]
                    )
                    env.DEPLOY_STRATEGY = deployApproval.DEPLOY_STRATEGY
                }
            }
        }

        // ========== 阶段9: 部署到生产 ==========
        stage('Deploy to Production') {
            steps {
                echo "🚀 部署到生产环境..."
                script {
                    switch(env.DEPLOY_STRATEGY) {
                        case 'rolling':
                            sh '''
                                kubectl set image deployment/${K8S_DEPLOYMENT} \
                                    ${IMAGE_NAME}=${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG} \
                                    -n ${K8S_NAMESPACE}
                            '''
                            break
                        case 'blue-green':
                            sh '''
                                # 创建新版本Deployment
                                kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${K8S_DEPLOYMENT}-blue
  namespace: ${K8S_NAMESPACE}
spec:
  replicas: 3
  selector:
    matchLabels:
      app: ${K8S_DEPLOYMENT}
      version: blue
  template:
    metadata:
      labels:
        app: ${K8S_DEPLOYMENT}
        version: blue
    spec:
      containers:
      - name: ${IMAGE_NAME}
        image: ${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}
        ports:
        - containerPort: 8000
EOF
                            '''
                            break
                        case 'canary':
                            sh '''
                                # 创建金丝雀Deployment (10%流量)
                                kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${K8S_DEPLOYMENT}-canary
  namespace: ${K8S_NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${K8S_DEPLOYMENT}
      version: canary
  template:
    metadata:
      labels:
        app: ${K8S_DEPLOYMENT}
        version: canary
    spec:
      containers:
      - name: ${IMAGE_NAME}
        image: ${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}
        ports:
        - containerPort: 8000
EOF
                            '''
                            break
                    }
                    
                    // 等待部署完成
                    sh '''
                        kubectl rollout status deployment/${K8S_DEPLOYMENT} \
                            -n ${K8S_NAMESPACE} --timeout=600s
                    '''
                }
            }
        }

        // ========== 阶段10: 健康检查 ==========
        stage('Health Check') {
            steps {
                echo "🏥 健康检查..."
                sh '''
                    # 等待应用启动
                    for i in {1..30}; do
                        if kubectl exec -n ${K8S_NAMESPACE} \
                            deployment/${K8S_DEPLOYMENT} -- \
                            curl -sf http://localhost:8000/health; then
                            echo "✅ 应用健康检查通过"
                            exit 0
                        fi
                        echo "等待应用就绪... ($i/30)"
                        sleep 10
                    done
                    echo "❌ 健康检查失败"
                    exit 1
                '''
            }
            post {
                failure {
                    echo "❌ 部署失败，自动回滚..."
                    sh '''
                        kubectl rollout undo deployment/${K8S_DEPLOYMENT} \
                            -n ${K8S_NAMESPACE}
                        kubectl rollout status deployment/${K8S_DEPLOYMENT} \
                            -n ${K8S_NAMESPACE} --timeout=300s
                    '''
                    script {
                        notifyDingTalk("部署失败已自动回滚", "danger")
                    }
                }
            }
        }

        // ========== 阶段11: 清理Canary ==========
        stage('Cleanup Canary') {
            when {
                expression { env.DEPLOY_STRATEGY == 'canary' }
            }
            steps {
                echo "🧹 清理金丝雀实例..."
                sh '''
                    kubectl delete deployment ${K8S_DEPLOYMENT}-canary \
                        -n ${K8S_NAMESPACE} --ignore-not-found
                '''
            }
        }
    }

    // 构建后操作
    post {
        always {
            echo "🏁 流水线完成"
            // 清理工作空间
            cleanWs()
        }
        success {
            script {
                notifyDingTalk(
                    "✅ 构建成功\n版本: ${env.IMAGE_TAG}\n提交: ${env.GIT_COMMIT_SHORT}\n信息: ${env.GIT_COMMIT_MSG}",
                    "success"
                )
            }
        }
        failure {
            script {
                notifyDingTalk(
                    "❌ 构建失败\n版本: ${env.IMAGE_TAG}\n请检查: ${env.BUILD_URL}",
                    "danger"
                )
            }
        }
    }
}

// ========== 通知函数 ==========
def notifyDingTalk(String message, String level) {
    def color = 'info'
    if (level == 'success') color = 'green'
    if (level == 'warning') color = 'orange'
    if (level == 'danger') color = 'red'
    
    sh """
        curl -s -X POST '${DINGTALK_WEBHOOK}' \
            -H 'Content-Type: application/json' \
            -d '{
                "msgtype": "markdown",
                "markdown": {
                    "title": "CI/CD通知",
                    "text": "### Jenkins构建通知\\n\\n> **级别**: ${level}\\n\\n> **信息**: ${message}\\n\\n> **时间**: ${new Date().format('yyyy-MM-dd HH:mm:ss')}"
                }
            }'
    """
}
```

---

## 📋 Kubernetes部署清单

### k8s/base/deployment.yaml

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: enterprise-app
  namespace: production
  labels:
    app: enterprise-app
    version: v1
spec:
  replicas: 3
  revisionHistoryLimit: 10
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  selector:
    matchLabels:
      app: enterprise-app
  template:
    metadata:
      labels:
        app: enterprise-app
        version: v1
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "8000"
    spec:
      serviceAccountName: enterprise-app
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        fsGroup: 1000
      containers:
      - name: app
        image: registry:5000/enterprise-app:latest
        ports:
        - containerPort: 8000
          name: http
        envFrom:
        - configMapRef:
            name: enterprise-app-config
        - secretRef:
            name: enterprise-app-secrets
        resources:
          requests:
            cpu: 250m
            memory: 256Mi
          limits:
            cpu: 1000m
            memory: 1Gi
        livenessProbe:
          httpGet:
            path: /health
            port: 8000
          initialDelaySeconds: 15
          periodSeconds: 20
          timeoutSeconds: 5
          failureThreshold: 3
        readinessProbe:
          httpGet:
            path: /ready
            port: 8000
          initialDelaySeconds: 5
          periodSeconds: 10
          timeoutSeconds: 3
          failureThreshold: 3
        startupProbe:
          httpGet:
            path: /health
            port: 8000
          initialDelaySeconds: 10
          periodSeconds: 5
          failureThreshold: 30
      topologySpreadConstraints:
      - maxSkew: 1
        topologyKey: kubernetes.io/hostname
        whenUnsatisfiable: DoNotSchedule
        labelSelector:
          matchLabels:
            app: enterprise-app
```

### k8s/base/service.yaml

```yaml
apiVersion: v1
kind: Service
metadata:
  name: enterprise-app
  namespace: production
  labels:
    app: enterprise-app
spec:
  type: ClusterIP
  ports:
  - port: 80
    targetPort: 8000
    protocol: TCP
    name: http
  selector:
    app: enterprise-app
```

### k8s/base/ingress.yaml

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: enterprise-app
  namespace: production
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/proxy-body-size: "50m"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "60"
    nginx.ingress.kubernetes.io/rate-limit: "100"
    nginx.ingress.kubernetes.io/rate-limit-window: "1m"
    cert-manager.io/cluster-issuer: "letsencrypt-prod"
spec:
  ingressClassName: nginx
  tls:
  - hosts:
    - app.your-domain.com
    secretName: app-tls
  rules:
  - host: app.your-domain.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: enterprise-app
            port:
              number: 80
```

### k8s/base/hpa.yaml

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: enterprise-app
  namespace: production
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: enterprise-app
  minReplicas: 3
  maxReplicas: 20
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 70
  - type: Resource
    resource:
      name: memory
      target:
        type: Utilization
        averageUtilization: 80
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 60
      policies:
      - type: Pods
        value: 4
        periodSeconds: 60
    scaleDown:
      stabilizationWindowSeconds: 300
      policies:
      - type: Percent
        value: 10
        periodSeconds: 120
```

### k8s/base/pdb.yaml

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: enterprise-app
  namespace: production
spec:
  minAvailable: 2
  selector:
    matchLabels:
      app: enterprise-app
```

---

## 🔧 运维手册

### Jenkins常用操作

```bash
# 查看Jenkins日志
docker logs -f jenkins

# 获取初始管理员密码
docker exec jenkins cat /var/jenkins_home/secrets/initialAdminPassword

# 备份Jenkins
docker exec jenkins tar czf /tmp/jenkins-backup.tar.gz /var/jenkins_home
docker cp jenkins:/tmp/jenkins-backup.tar.gz ./backup/

# 安装常用插件
# Pipeline, GitHub Integration, Docker Pipeline, Kubernetes, Blue Ocean
```

### ArgoCD常用操作

```bash
# 登录ArgoCD
argocd login localhost:8443 --insecure

# 创建应用
argocd app create enterprise-app \
    --repo https://github.com/your-org/k8s-manifests.git \
    --path apps/enterprise-app \
    --dest-server https://kubernetes.default.svc \
    --dest-namespace production \
    --sync-policy automated \
    --auto-prune \
    --self-heal

# 查看同步状态
argocd app get enterprise-app

# 手动同步
argocd app sync enterprise-app

# 回滚
argocd app history enterprise-app
argocd app rollback enterprise-app <revision>
```

### Harbor常用操作

```bash
# 登录Harbor
docker login harbor.your-domain.com

# 推送镜像
docker tag app:latest harbor.your-domain.com/project/app:v1.0
docker push harbor.your-domain.com/project/app:v1.0

# 拉取镜像
docker pull harbor.your-domain.com/project/app:v1.0
```

---

**作者**: 企业级运维项目集
**版本**: 1.0.0
**更新时间**: 2026-05-02
