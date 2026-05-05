# 企业级CI/CD全链路 - GitLab CI + SonarQube + Harbor + ArgoCD + Kubernetes

> 完整实现从代码提交到生产部署的全自动化流水线
> 覆盖: 代码扫描、单元测试、安全扫描、镜像构建、自动部署、灰度发布、自动回滚
> 适用于: 中大型研发团队的DevOps转型

---

> ⚠️ **安全声明**: 本文档中的密码(如${MYSQL_ROOT_PASSWORD}、${HARBOR_ADMIN_PASSWORD}等)均为示例占位符。
> 生产环境必须使用密钥管理工具(Vault/K8s Secrets/环境变量)管理敏感信息，
> 切勿将真实密码硬编码在配置文件或脚本中。

## 一、项目架构

```
开发者 ──push──▶ GitLab ──webhook──▶ Jenkins ──构建──▶ Harbor ──同步──▶ ArgoCD ──部署──▶ K8s
                    │                    │                    │
                    ▼                    ▼                    ▼
               代码评审             SonarQube            Trivy扫描
               Merge Request       代码质量              镜像安全
```

### 完整流水线阶段

```
┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────┐
│ 代码检出 │→│ 依赖安装 │→│ 编译构建 │→│ 单元测试 │→│ 代码扫描 │→│ 镜像构建 │→│ 镜像推送 │
└─────────┘  └─────────┘  └─────────┘  └─────────┘  └─────────┘  └─────────┘  └─────────┘
                                                                              │
┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────┐             │
│ 生产验证 │←│ 灰度发布 │←│ 预发验证 │←│ Staging │←│ 安全扫描 │←────────────┘
└─────────┘  └─────────┘  └─────────┘  └─────────┘  └─────────┘
```

---

## 二、服务器规划

| 服务 | IP | 配置 | 用途 |
|------|-----|------|------|
| GitLab | 10.10.20.11 | 8C/16G/500G | 代码仓库 |
| Jenkins | 10.10.20.12 | 8C/16G/200G | CI引擎 |
| SonarQube | 10.10.20.13 | 8C/16G/100G | 代码质量 |
| Harbor | 10.10.10.31 | 8C/16G/2T | 镜像仓库 |
| ArgoCD | 10.10.10.11(K8s) | - | GitOps部署 |
| K8s集群 | 10.10.10.x | - | 运行环境 |

---

## 三、GitLab部署与配置

```bash
#!/bin/bash
# install_gitlab.sh - 在10.10.20.11上执行

set -euo pipefail

echo "安装GitLab CE..."
curl -fsSL https://packages.gitlab.com/install/repositories/gitlab/gitlab-ce/script.rpm.sh | bash

EXTERNAL_URL="https://gitlab.internal.com"
GITLAB_ROOT_PASSWORD="${GITLAB_ROOT_PASSWORD}"

cat > /etc/gitlab/gitlab.rb << EOF
external_url '${EXTERNAL_URL}'
gitlab_rails['gitlab_shell_ssh_port'] = 2222
gitlab_rails['initial_root_password'] = '${GITLAB_ROOT_PASSWORD}'

# 启用Container Registry
registry_external_url 'https://harbor.internal.com'
registry_nginx['enable'] = false

# 启用Pages
pages_external_url 'https://pages.gitlab.internal.com'

# 备份配置
gitlab_rails['backup_path'] = '/var/opt/gitlab/backups'
gitlab_rails['backup_keep_time'] = 604800  # 7天

# 性能优化
puma['worker_processes'] = 4
sidekiq['max_concurrency'] = 20
postgresql['shared_buffers'] = "2GB"
postgresql['work_mem'] = "16MB"
postgresql['maintenance_work_mem'] = "512MB"

# 邮件通知
gitlab_rails['smtp_enable'] = true
gitlab_rails['smtp_address'] = "smtp.feishu.cn"
gitlab_rails['smtp_port'] = 465
gitlab_rails['smtp_user_name'] = "ci-bot@company.com"
gitlab_rails['smtp_password'] = "smtp-password"
gitlab_rails['smtp_domain'] = "feishu.cn"
gitlab_rails['smtp_authentication'] = "login"
gitlab_rails['smtp_enable_starttls_auto'] = true
gitlab_rails['smtp_tls'] = true
gitlab_rails['gitlab_email_from'] = 'ci-bot@company.com'
EOF

gitlab-ctl reconfigure
gitlab-ctl restart

echo "✅ GitLab安装完成"
echo "URL: ${EXTERNAL_URL}"
echo "Root密码: ${GITLAB_ROOT_PASSWORD}"
```

### 3.1 创建项目模板

```bash
#!/bin/bash
# setup_gitlab_project.sh - 创建标准化项目

set -euo pipefail

GITLAB_URL="https://gitlab.internal.com"
TOKEN="your-gitlab-api-token"

# 创建Group
curl -k --header "PRIVATE-TOKEN: ${TOKEN}" \
  "${GITLAB_URL}/api/v4/groups" \
  --data "name=platform" \
  --data "path=platform" \
  --data "visibility=private"

# 创建项目
curl -k --header "PRIVATE-TOKEN: ${TOKEN}" \
  "${GITLAB_URL}/api/v4/projects" \
  --data "name=user-service" \
  --data "path=user-service" \
  --data "namespace_id=1" \
  --data "default_branch=main" \
  --data "initialize_with_readme=true"
```

### 3.2 项目标准化模板 - .gitlab-ci.yml

```yaml
# .gitlab-ci.yml - 企业级CI/CD标准模板
# 放在项目根目录，所有微服务共用

variables:
  # 镜像仓库
  HARBOR_REGISTRY: harbor.internal.com
  HARBOR_PROJECT: production
  IMAGE_NAME: ${HARBOR_REGISTRY}/${HARBOR_PROJECT}/${CI_PROJECT_NAME}
  
  # SonarQube
  SONAR_HOST: http://sonar.internal.com:9000
  
  # Docker构建
  DOCKER_TLS_CERTDIR: "/certs"
  
  # K8s部署
  K8S_NAMESPACE: production
  ARGOCD_SERVER: argocd.internal.com

stages:
  - checkout
  - build
  - test
  - scan
  - image
  - security
  - deploy-staging
  - verify-staging
  - deploy-production
  - verify-production

# ========================================
# 阶段1: 代码检出
# ========================================
checkout:
  stage: checkout
  image: alpine/git:latest
  script:
    - echo "代码检出完成"
  rules:
    - if: $CI_COMMIT_BRANCH == "main" || $CI_COMMIT_BRANCH == "develop"
    - if: $CI_COMMIT_BRANCH =~ /^release\/.*$/
    - if: $CI_COMMIT_BRANCH =~ /^hotfix\/.*$/
    - /^hotfix\/.*$/

# ========================================
# 阶段2: 编译构建
# ========================================
build-java:
  stage: build
  image: maven:3.9-eclipse-temurin-17
  script:
    - echo "Maven构建..."
    - mvn clean package -DskipTests -B
    - mkdir -p target/docker
    - cp target/*.jar target/docker/app.jar
    - cp Dockerfile target/docker/
  artifacts:
    paths:
      - target/docker/
    expire_in: 2 hours
  rules:
    - if: $CI_COMMIT_BRANCH == "main"
    - if: $CI_COMMIT_BRANCH == "develop"
build-go:
  stage: build
  image: golang:1.21-alpine
  script:
    - echo "Go构建..."
    - go mod tidy
    - CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o target/docker/app .
  artifacts:
    paths:
      - target/docker/
    expire_in: 2 hours
  rules:
    - if: $CI_COMMIT_BRANCH == "main"
    - if: $CI_COMMIT_BRANCH == "develop"

build-node:
  stage: build
  image: node:20-alpine
  script:
    - echo "Node.js构建..."
    - npm ci --production
    - npm run build
    - mkdir -p target/docker
    - cp -r dist/ target/docker/
    - cp -r node_modules/ target/docker/
    - cp Dockerfile target/docker/
  artifacts:
    paths:
      - target/docker/
    expire_in: 2 hours
  rules:
    - if: $CI_COMMIT_BRANCH == "main"
    - if: $CI_COMMIT_BRANCH == "develop"

# ========================================
# 阶段3: 单元测试
# ========================================
unit-test:
  stage: test
  image: maven:3.9-eclipse-temurin-17
  script:
    - echo "运行单元测试..."
    - mvn test -B
    - mvn jacoco:report
  artifacts:
    reports:
      junit: target/surefire-reports/TEST-*.xml
      coverage_report:
        coverage_format: cobertura
        path: target/site/jacoco/jacoco.xml
    expire_in: 7 days
  coverage: '/Code coverage: (\d+\.?\d*)%/'
  rules:
    - if: $CI_COMMIT_BRANCH == "main"
    - if: $CI_COMMIT_BRANCH == "develop"

# ========================================
# 阶段4: SonarQube代码扫描
# ========================================
sonarqube-analysis:
  stage: scan
  image: sonarsource/sonar-scanner-cli:4.8
  variables:
    SONAR_USER_HOME: "${CI_PROJECT_DIR}/.sonar"
  script:
    - echo "SonarQube代码扫描..."
    - >
      sonar-scanner
      -Dsonar.projectKey=${CI_PROJECT_NAME}
      -Dsonar.sources=src/
      -Dsonar.host.url=${SONAR_HOST}
      -Dsonar.login=${SONAR_TOKEN}
      -Dsonar.java.binaries=target/classes/
      -Dsonar.java.libraries=target/dependency/
      -Dsonar.qualitygate.wait=true
      -Dsonar.qualitygate.timeout=300
  allow_failure: false
  rules:
    - if: $CI_COMMIT_BRANCH == "main"
    - if: $CI_COMMIT_BRANCH == "develop"

# ========================================
# 阶段5: 构建Docker镜像
# ========================================
build-image:
  stage: image
  # [注意] docker:dind需privileged:true，有安全风险。生产环境建议改用Kaniko或Buildah构建镜像
  image: docker:26-dind
  services:
    - docker:26-dind
  before_script:
    - echo "${HARBOR_PASSWORD}" | docker login -u ${HARBOR_USER} --password-stdin ${HARBOR_REGISTRY}
  script:
# [Kaniko替代方案] 无需privileged权限:
# build-image-kaniko:
#   stage: image
#   image: gcr.io/kaniko-project/executor:debug
#   script:
#     - /kaniko/executor --context=${CI_PROJECT_DIR} --dockerfile=Dockerfile --destination=${HARBOR_REGISTRY}/app:${CI_COMMIT_SHA} --cache=true
    - |
      # 多标签策略
      export TAG_LATEST="${IMAGE_NAME}:latest"
      export TAG_COMMIT="${IMAGE_NAME}:${CI_COMMIT_SHORT_SHA}"
      export TAG_BRANCH="${IMAGE_NAME}:${CI_COMMIT_REF_SLUG}"
      export TAG_SEMVER="${IMAGE_NAME}:${CI_COMMIT_TAG}"
      
      echo "构建镜像..."
      docker build \
        --build-arg BUILD_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ) \
        --build-arg VCS_REF=${CI_COMMIT_SHA} \
        --build-arg VERSION=${CI_COMMIT_TAG:-${CI_COMMIT_SHORT_SHA}} \
        -t ${TAG_COMMIT} \
        -f Dockerfile .
      
      docker tag ${TAG_COMMIT} ${TAG_LATEST}
      docker tag ${TAG_COMMIT} ${TAG_BRANCH}
      
      echo "推送镜像..."
      docker push ${TAG_COMMIT}
      docker push ${TAG_LATEST}
      docker push ${TAG_BRANCH}
      
      # 如果是tag推送 semver 标签
      if [ -n "${CI_COMMIT_TAG}" ]; then
        docker tag ${TAG_COMMIT} ${TAG_SEMVER}
        docker push ${TAG_SEMVER}
      fi
      
      echo "镜像地址: ${TAG_COMMIT}"
  rules:
    - if: $CI_COMMIT_BRANCH == "main"
    - if: $CI_COMMIT_BRANCH == "develop"
    - if: $CI_COMMIT_BRANCH =~ ^release\/.*$
    - if: $CI_COMMIT_TAG

# ========================================
# 阶段6: Trivy安全扫描
# ========================================
trivy-scan:
  stage: security
  image:
    name: aquasec/trivy:latest
    entrypoint: [""]
  script:
    - echo "Trivy镜像安全扫描..."
    - >
      trivy image
      --exit-code 1
      --severity HIGH,CRITICAL
      --ignore-unfixed
      --no-progress
      --format table
      ${IMAGE_NAME}:${CI_COMMIT_SHORT_SHA}
  allow_failure: false
  rules:
    - if: $CI_COMMIT_BRANCH == "main"
    - if: $CI_COMMIT_TAG

# ========================================
# 阶段7: 部署到Staging
# ========================================
deploy-staging:
  stage: deploy-staging
  image: bitnami/kubectl:latest
  environment:
    name: staging
    url: https://staging.${CI_PROJECT_NAME}.internal.com
  script:
    - echo "部署到Staging环境..."
    - kubectl config use-context staging
    - |
      # 更新镜像版本
      kubectl set image deployment/${CI_PROJECT_NAME} \
        ${CI_PROJECT_NAME}=${IMAGE_NAME}:${CI_COMMIT_SHORT_SHA} \
        -n staging
      # 等待 rollout 完成
      kubectl rollout status deployment/${CI_PROJECT_NAME} -n staging --timeout=300s
  rules:
    - if: $CI_COMMIT_BRANCH == "main"
      when: manual

# ========================================
# 阶段8: Staging验证
# ========================================
verify-staging:
  stage: verify-staging
  image: curlimages/curl:latest
  script:
    - echo "Staging环境健康检查..."
    - |
      MAX_RETRIES=30
      RETRY_INTERVAL=10
      for i in $(seq 1 $MAX_RETRIES); do
        HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" \
          https://staging.${CI_PROJECT_NAME}.internal.com/health)
        if [ "$HTTP_CODE" = "200" ]; then
          echo "✅ Staging环境健康检查通过"
          exit 0
        fi
        echo "尝试 $i/$MAX_RETRIES: HTTP $HTTP_CODE"
        sleep $RETRY_INTERVAL
      done
      echo "❌ Staging环境健康检查失败"
      exit 1
  rules:
    - if: $CI_COMMIT_BRANCH == "main"

# ========================================
# 阶段9: 部署到生产
# ========================================
deploy-production:
  stage: deploy-production
  image: bitnami/kubectl:latest
  environment:
    name: production
    url: https://${CI_PROJECT_NAME}.internal.com
  script:
    - echo "部署到生产环境..."
    - kubectl config use-context production
    - |
      # 记录当前版本（用于回滚）
      CURRENT_IMAGE=$(kubectl get deployment/${CI_PROJECT_NAME} -n production \
        -o jsonpath='{.spec.template.spec.containers[0].image}')
      echo "当前版本: ${CURRENT_IMAGE}"
      
      # 滚动更新
      kubectl set image deployment/${CI_PROJECT_NAME} \
        ${CI_PROJECT_NAME}=${IMAGE_NAME}:${CI_COMMIT_SHORT_SHA} \
        -n production
      
      # 等待完成
      kubectl rollout status deployment/${CI_PROJECT_NAME} -n production --timeout=600s
  when: manual
  rules:
    - if: $CI_COMMIT_BRANCH == "main"
    - if: $CI_COMMIT_TAG

# ========================================
# 阶段10: 生产验证
# ========================================
verify-production:
  stage: verify-production
  image: curlimages/curl:latest
  script:
    - echo "生产环境健康检查..."
    - |
      MAX_RETRIES=30
      RETRY_INTERVAL=10
      for i in $(seq 1 $MAX_RETRIES); do
        HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" \
          https://${CI_PROJECT_NAME}.internal.com/health)
        if [ "$HTTP_CODE" = "200" ]; then
          echo "✅ 生产环境健康检查通过"
          exit 0
        fi
        echo "尝试 $i/$MAX_RETRIES: HTTP $HTTP_CODE"
        sleep $RETRY_INTERVAL
      done
      echo "❌ 生产环境健康检查失败，触发自动回滚..."
      kubectl rollout undo deployment/${CI_PROJECT_NAME} -n production
      echo "已自动回滚到上一版本"
      exit 1
  rules:
    - if: $CI_COMMIT_BRANCH == "main"
    - if: $CI_COMMIT_TAG

# ========================================
# 回滚Job（手动触发）
# ========================================
rollback-production:
  stage: deploy-production
  image: bitnami/kubectl:latest
  script:
    - echo "手动回滚生产环境..."
    - kubectl rollout undo deployment/${CI_PROJECT_NAME} -n production
    - kubectl rollout status deployment/${CI_PROJECT_NAME} -n production --timeout=300s
  when: manual
  rules:
    - if: $CI_COMMIT_BRANCH == "main"
```

---

## 四、Dockerfile最佳实践

```dockerfile
# Dockerfile - 多阶段构建模板
# ========================================

# Stage 1: 构建
FROM maven:3.9-eclipse-temurin-17 AS builder
WORKDIR /build
COPY pom.xml .
RUN mvn dependency:go-offline -B
COPY src/ src/
RUN mvn clean package -DskipTests -B

# Stage 2: 运行
FROM eclipse-temurin:17-jre-jammy AS runtime  # Ubuntu(jammy)

# 安全: 创建非root用户(Ubuntu语法)
RUN groupadd -r appgroup && useradd -r -g appgroup -s /bin/false appuser

# 安装时区(Ubuntu用apt-get)
RUN apt-get update && apt-get install -y --no-install-recommends tzdata && \
    rm -rf /var/lib/apt/lists/* && \
    ln -snf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime && \
    echo "Asia/Shanghai" > /etc/timezone

WORKDIR /app

# 复制构建产物
COPY --from=builder /build/target/*.jar app.jar

# 切换到非root用户
USER appuser

# 健康检查
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
  CMD wget -qO- http://localhost:8080/actuator/health || exit 1

# 元数据标签
LABEL maintainer="platform-team@company.com" \
      version="1.0" \
      description="Enterprise Microservice"

EXPOSE 8080

# JVM参数优化（容器感知）
ENTRYPOINT ["java", \
  "-XX:+UseContainerSupport", \
  "-XX:MaxRAMPercentage=75.0", \
  "-XX:InitialRAMPercentage=50.0", \
  "-XX:+UseG1GC", \
  "-XX:MaxGCPauseMillis=200", \
  "-Djava.security.egd=file:/dev/./urandom", \
  "-jar", "app.jar"]
```

---

## 五、SonarQube部署

```bash
#!/bin/bash
# install_sonarqube.sh - 在10.10.20.13上执行

set -euo pipefail

echo "安装PostgreSQL..."
# [生产建议] 使用外部PostgreSQL(阿里云RDS或已有PG集群)，避免本地安装
yum install -y postgresql-server postgresql
postgresql-setup --initdb
systemctl enable postgresql
systemctl start postgresql

sudo -u postgres psql -c "CREATE USER sonarqube WITH PASSWORD '${SONARQUBE_DB_PASSWORD}';"
sudo -u postgres psql -c "CREATE DATABASE sonarqube OWNER sonarqube;"
sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE sonarqube TO sonarqube;"

# 配置pg_hba.conf允许密码认证
sed -i 's/^local.*all.*all.*peer/local   all             all                                     md5/' /var/lib/pgsql/data/pg_hba.conf

echo "安装SonarQube..."
cd /opt
SONAR_VERSION="10.4.0.88267"
wget https://binaries.sonarsource.com/Distribution/sonarqube/sonarqube-${SONAR_VERSION}.zip
unzip sonarqube-${SONAR_VERSION}.zip
ln -sf sonarqube-${SONAR_VERSION} sonarqube

# JVM优化
cat > /opt/sonarqube/conf/sonar.properties << EOF
sonar.jdbc.username=sonarqube
sonar.jdbc.password=${SONARQUBE_DB_PASSWORD}
sonar.jdbc.url=jdbc:postgresql://localhost/sonarqube?currentSchema=public
# [生产建议] 使用独立PostgreSQL: jdbc:postgresql://sonar-db-host:5432/sonarqube
# 或使用阿里云RDS PostgreSQL，避免同机部署导致资源竞争
sonar.web.javaAdditionalOpts=-server -Xms1g -Xmx2g -XX:+UseG1GC
sonar.ce.javaAdditionalOpts=-server -Xms1g -Xmx4g -XX:+UseG1GC
sonar.search.javaAdditionalOpts=-server -Xms1g -Xmx2g -XX:+UseG1GC
sonar.core.serverBaseURL=https://sonar.internal.com
sonar.authenticator.downcased=true
EOF

# 内核参数（SonarQube需要）
echo "vm.max_map_count=524288" >> /etc/sysctl.d/99-sonarqube.conf
sysctl -p /etc/sysctl.d/99-sonarqube.conf

# 创建systemd服务
cat > /etc/systemd/system/sonarqube.service << EOF
[Unit]
Description=SonarQube
After=network.target postgresql.service

[Service]
Type=forking
ExecStart=/opt/sonarqube/bin/linux-x86-64/sonar.sh start
ExecStop=/opt/sonarqube/bin/linux-x86-64/sonar.sh stop
User=sonar
Group=sonar
Restart=always
LimitNOFILE=65536
LimitNPROC=4096

[Install]
WantedBy=multi-user.target
EOF

# [已修复] 先创建用户再解压，避免目录权限问题
useradd -r -s /bin/false sonar 2>/dev/null || true
chown -R sonar:sonar /opt/sonarqube

systemctl daemon-reload
systemctl enable sonarqube
systemctl start sonarqube

echo "✅ SonarQube安装完成"
echo "访问: http://10.10.20.13:9000"
echo "默认账号: admin/admin"
```

### 5.1 SonarQube质量门禁配置

```json
// quality-gate.json - 企业级质量门禁规则
{
  "name": "Enterprise Quality Gate",
  "conditions": [
    {
      "metric": "new_coverage",
      "operator": "LESS_THAN",
      "error_threshold": "80",
      "period": 1
    },
    {
      "metric": "new_duplicated_lines_density",
      "operator": "GREATER_THAN",
      "error_threshold": "3",
      "period": 1
    },
    {
      "metric": "new_blocker_violations",
      "operator": "GREATER_THAN",
      "error_threshold": "0",
      "period": 1
    },
    {
      "metric": "new_critical_violations",
      "operator": "GREATER_THAN",
      "error_threshold": "0",
      "period": 1
    },
    {
      "metric": "new_major_violations",
      "operator": "GREATER_THAN",
      "error_threshold": "5",
      "period": 1
    },
    {
      "metric": "new_bugs",
      "operator": "GREATER_THAN",
      "error_threshold": "0",
      "period": 1
    },
    {
      "metric": "new_vulnerabilities",
      "operator": "GREATER_THAN",
      "error_threshold": "0",
      "period": 1
    },
    {
      "metric": "new_security_hotspots_reviewed",
      "operator": "LESS_THAN",
      "error_threshold": "100",
      "period": 1
    }
  ]
}
```

---

## 六、Jenkins部署与配置

```bash
#!/bin/bash
# install_jenkins.sh - 在10.10.20.12上执行

set -euo pipefail

echo "安装Jenkins..."
wget -O /etc/yum.repos.d/jenkins.repo https://pkg.jenkins.io/redhat-stable/jenkins.repo
rpm --import https://pkg.jenkins.io/redhat-stable/jenkins.io-2024.key
# [注意] GPG key每年更新，如安装失败请检查 https://www.jenkins.io/download/ 获取最新key

# 安装JDK
yum install -y java-17-openjdk java-17-openjdk-devel

# 安装Jenkins
yum install -y jenkins-2.426.3

# 配置Jenkins
cat > /etc/default/jenkins << EOF
JENKINS_PORT=8080
JAVA_HOME=/usr/lib/jvm/java-17-openjdk
JAVA_OPTS="-Xms2g -Xmx4g -Djava.awt.headless=true -Djenkins.install.runSetupWizard=false"
EOF

systemctl enable jenkins
systemctl start jenkins

echo "Jenkins初始密码:"
cat /var/lib/jenkins/secrets/initialAdminPassword
```

### 6.1 Jenkins Pipeline共享库

> **Shared Library仓库结构**:
> ```
> enterprise-pipeline-lib/
> ├── vars/                    # 全局变量/函数(在Pipeline中直接调用)
> │   ├── enterprisePipeline.groovy   # 主Pipeline模板
> │   ├── buildJava.groovy            # Java构建步骤
> │   └── deployK8s.groovy            # K8s部署步骤
> ├── src/                     # Groovy源码(可选)
> │   └── com/
> │       └── enterprise/
> │           └── pipeline/
> │               └── Utils.groovy
> ├── resources/               # 非Groovy资源文件
> │   └── templates/
> └── README.md
> ```
> 在Jenkins中配置: Manage Jenkins → Configure System → Global Pipeline Libraries
> - Name: enterprise-lib
> - Default version: main
> - Source: Git, URL: https://gitlab.internal.com/platform/enterprise-pipeline-lib.git

```groovy
// vars/enterprisePipeline.groovy - 共享Pipeline库
// 放在 Jenkins Shared Library 仓库中

def call(Map config = [:]) {
    def defaultConfig = [
        appName: env.JOB_NAME,
        language: 'java',
        dockerfile: 'Dockerfile',
        harborProject: 'production',
        k8sNamespace: 'production',
        sonarQualityGate: true,
        trivyScan: true,
        autoDeploy: false,
        healthCheckUrl: '/health',
        healthCheckRetries: 30,
        healthCheckInterval: 10,
    ]
    def cfg = defaultConfig + config
    
    pipeline {
        agent {
            kubernetes {
                yaml """
apiVersion: v1
kind: Pod
spec:
  containers:
  - name: jnlp
    image: jenkins/inbound-agent:latest
  - name: docker
    image: docker:26-dind
    securityContext:
      privileged: true
    env:
    - name: DOCKER_TLS_CERTDIR
      value: ""
  - name: kubectl
    image: bitnami/kubectl:latest
    command: ['sleep', 'infinity']
  - name: trivy
    image: aquasec/trivy:latest
    command: ['sleep', 'infinity']
"""
            }
        }
        
        options {
            timeout(time: 30, unit: 'MINUTES')
            disableConcurrentBuilds()
            buildDiscarder(logRotator(numToKeepStr: '20'))
            timestamps()
        }
        
        environment {
            HARBOR_REGISTRY = 'harbor.internal.com'
            HARBOR_PROJECT = cfg.harborProject
            IMAGE_NAME = "${HARBOR_REGISTRY}/${HARBOR_PROJECT}/${cfg.appName}"
            SONAR_TOKEN = credentials('sonar-token')
            HARBOR_CREDS = credentials('harbor-creds')
        }
        
        stages {
            stage('构建') {
                steps {
                    container('docker') {
                        script {
                            sh """
                                echo "${HARBOR_CREDS_PSW}" | docker login -u ${HARBOR_CREDS_USR} --password-stdin ${HARBOR_REGISTRY}
                                docker build -t ${IMAGE_NAME}:${env.BUILD_NUMBER} -f ${cfg.dockerfile} .
                                docker push ${IMAGE_NAME}:${env.BUILD_NUMBER}
                            """
                        }
                    }
                }
            }
            
            stage('安全扫描') {
                when { expression { return cfg.trivyScan } }
                steps {
                    container('trivy') {
                        sh """
                            trivy image --exit-code 1 --severity HIGH,CRITICAL \
                              ${IMAGE_NAME}:${env.BUILD_NUMBER}
                        """
                    }
                }
            }
            
            stage('部署') {
                when { expression { return cfg.autoDeploy } }
                steps {
                    container('kubectl') {
                        sh """
                            kubectl set image deployment/${cfg.appName} \
                              ${cfg.appName}=${IMAGE_NAME}:${env.BUILD_NUMBER} \
                              -n ${cfg.k8sNamespace}
                            kubectl rollout status deployment/${cfg.appName} \
                              -n ${cfg.k8sNamespace} --timeout=300s
                        """
                    }
                }
            }
        }
        
        post {
            success {
                echo "✅ 构建成功: ${IMAGE_NAME}:${env.BUILD_NUMBER}"
            }
            failure {
                echo "❌ 构建失败，触发告警..."
                // 钉钉/企业微信通知
            }
        }
    }
}
```

---

## 七、ArgoCD GitOps部署

```bash
#!/bin/bash
# install_argocd.sh - 安装ArgoCD

set -euo pipefail

echo "创建namespace..."
kubectl create namespace argocd

echo "安装ArgoCD..."
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

echo "等待就绪..."
kubectl -n argocd rollout status deployment/argocd-server --timeout=300s

echo "获取初始密码..."
ARGOCD_PWD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
echo "ArgoCD密码: ${ARGOCD_PWD}"

echo "暴露服务..."
kubectl -n argocd patch svc argocd-server -p '{"spec": {"type": "LoadBalancer", "loadBalancerIP": "10.10.10.212"}}'

echo "✅ ArgoCD安装完成"
echo "URL: http://10.10.10.212"
echo "用户名: admin / 密码: ${ARGOCD_PWD}"
# [生产建议] 配置Ingress+TLS替代HTTP LoadBalancer:
# kubectl apply -f argocd-ingress.yaml  # 含cert-manager TLS注解
# 生产环境禁止通过HTTP暴露ArgoCD管理界面
```

### 7.1 ArgoCD Application配置

```yaml
# argocd-application.yaml - GitOps应用定义
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: user-service
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: production
  
  source:
    repoURL: https://gitlab.internal.com/platform/user-service-deploy.git
    targetRevision: main
    path: overlays/production
    kustomize:
      namePrefix: prod-
  
  destination:
    server: https://kubernetes.default.svc
    namespace: production
  
  syncPolicy:
      # [注意] selfHeal在生产中可能导致意外回滚，建议先在staging验证
      # 如需自动回滚，将selfHeal改为true
    automated:
      prune: true
      selfHeal: true  # 自动修复偏离Git状态的资源(自动回滚)
      allowEmpty: false
    syncOptions:
      - CreateNamespace=true
      - PrunePropagationPolicy=foreground
      - PruneLast=true
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
  
  ignoreDifferences:
    - group: apps
      kind: Deployment
      jsonPointers:
        - /spec/replicas
  
  healthChecks:
    - apiVersion: apps/v1
      kind: Deployment
      name: user-service
      namespace: production
```

### 7.2 K8s部署清单 - Kustomize结构

```yaml
# base/deployment.yaml - 基础Deployment配置
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: user-service
  labels:
    app: user-service
    team: platform
spec:
  replicas: 3
  selector:
    matchLabels:
      app: user-service
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  template:
    metadata:
      labels:
        app: user-service
        version: v1
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "8080"
        prometheus.io/path: "/metrics"
    spec:
      serviceAccountName: user-service
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
      containers:
        - name: user-service
          image: harbor.internal.com/production/user-service:latest
          ports:
            - containerPort: 8080
              name: http
            - containerPort: 8081
              name: management
          env:
            - name: SPRING_PROFILES_ACTIVE
              value: "production"
            - name: JAVA_OPTS
              value: "-XX:+UseContainerSupport -XX:MaxRAMPercentage=75.0"
            - name: DB_HOST
              valueFrom:
                secretKeyRef:
                  name: user-service-secrets
                  key: db-host
          resources:
            requests:
              cpu: 250m
              memory: 512Mi
            limits:
              cpu: 1000m
              memory: 1Gi
          livenessProbe:
            httpGet:
              path: /actuator/health/liveness
              port: 8081
            initialDelaySeconds: 60
            periodSeconds: 15
            timeoutSeconds: 5
          readinessProbe:
            httpGet:
              path: /actuator/health/readiness
              port: 8081
            initialDelaySeconds: 30
            periodSeconds: 10
            timeoutSeconds: 5
          startupProbe:
            httpGet:
              path: /actuator/health
              port: 8081
            initialDelaySeconds: 10
            periodSeconds: 5
            failureThreshold: 30
          lifecycle:
            preStop:
              exec:
                command: ["/bin/sh", "-c", "sleep 15"]
      terminationGracePeriodSeconds: 45
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app: user-service

---
# base/service.yaml
apiVersion: v1
kind: Service
metadata:
  name: user-service
spec:
  selector:
    app: user-service
  ports:
    - name: http
      port: 80
      targetPort: 8080
    - name: management
      port: 8081
      targetPort: 8081

---
# base/hpa.yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: user-service
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: user-service
  minReplicas: 3
  maxReplicas: 20
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 65

---
# base/pdb.yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: user-service
spec:
  minAvailable: 2
  selector:
    matchLabels:
      app: user-service

---
# overlays/production/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../base
namespace: production
namePrefix: prod-
commonLabels:
  environment: production
  team: platform
patches:
  - target:
      kind: Deployment
      name: user-service
    patch: |
      - op: replace
        path: /spec/replicas
        value: 5
      - op: replace
        path: /spec/template/spec/containers/0/resources/requests/cpu
        value: "500m"
      - op: replace
        path: /spec/template/spec/containers/0/resources/requests/memory
        value: "1Gi"
      - op: replace
        path: /spec/template/spec/containers/0/resources/limits/cpu
        value: "2"
      - op: replace
        path: /spec/template/spec/containers/0/resources/limits/memory
        value: "2Gi"
```

---

## 八、灰度发布与金丝雀发布

> **前置依赖**: 金丝雀发布需要Istio服务网格。部署Istio:
> ```bash
> istioctl install --set profile=default -y
> kubectl label namespace production istio-injection=enabled
> ```
> 如不使用Istio，可改用Nginx Ingress的canary annotation实现简单灰度。

```yaml
# canary-deployment.yaml - Istio金丝雀发布
---
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: user-service
spec:
  hosts:
    - user-service
  http:
    - route:
        - destination:
            host: user-service
            subset: stable
          weight: 90
        - destination:
            host: user-service
            subset: canary
          weight: 10
---
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: user-service
spec:
  host: user-service
  subsets:
    - name: stable
      labels:
        version: v1
    - name: canary
      labels:
        version: v2
```

```yaml
# canary-promotion.sh - 金丝雀晋升脚本
#!/bin/bash
# 逐步将流量从旧版本切换到新版本

SERVICE="user-service"
NAMESPACE="production"
CANARY_VERSION="v2"
CANARY_WAIT="${CANARY_WAIT:-300}"  # 金丝雀观察时间(秒)，可通过环境变量覆盖

echo "Phase 1: 10% -> 30%"
kubectl apply -f - << EOF
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: ${SERVICE}
spec:
  hosts:
    - ${SERVICE}
  http:
    - route:
        - destination:
            host: ${SERVICE}
            subset: stable
          weight: 70
        - destination:
            host: ${SERVICE}
            subset: canary
          weight: 30
EOF

sleep ${CANARY_WAIT}  # 观察期，基于CANARY_WAIT变量

echo "Phase 2: 30% -> 50%"
kubectl apply -f - << EOF
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: ${SERVICE}
spec:
  hosts:
    - ${SERVICE}
  http:
    - route:
        - destination:
            host: ${SERVICE}
            subset: stable
          weight: 50
        - destination:
            host: ${SERVICE}
            subset: canary
          weight: 50
EOF

sleep ${CANARY_WAIT}

echo "Phase 3: 50% -> 100% (全量切换)"
kubectl apply -f - << EOF
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: ${SERVICE}
spec:
  hosts:
    - ${SERVICE}
  http:
    - route:
        - destination:
            host: ${SERVICE}
            subset: canary
          weight: 100
EOF

echo "✅ 金丝雀晋升完成，全部流量已切换到 ${CANARY_VERSION}"
```

---

## 九、Webhook自动触发

### 9.1 GitLab → Jenkins Webhook

```bash
#!/bin/bash
# setup_webhook.sh - 配置GitLab自动触发Jenkins

set -euo pipefail

GITLAB_URL="https://gitlab.internal.com"
GITLAB_TOKEN="your-gitlab-token"
JENKINS_URL="http://jenkins.internal.com"
PROJECT_ID="1"  # GitLab项目ID

# 配置Webhook
curl -k --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  "${GITLAB_URL}/api/v4/projects/${PROJECT_ID}/hooks" \
  --data "url=${JENKINS_URL}/project/user-service/build" \
  --data "push_events=true" \
  --data "merge_requests_events=true" \
  --data "tag_push_events=true" \
  --data "enable_ssl_verification=false"
```

### 9.2 Jenkins → Harbor 镜像扫描

```yaml
# harbor-webhook-config.yaml - Harbor扫描完成后通知
webhook:
  targets:
    - name: jenkins
      url: http://jenkins.internal.com/generic-webhook-trigger/invoke
      auth_secret: "webhook-secret-2024"
      events:
        - SCAN_COMPLETED
        - QUARANTINE
```

---

## 十、完整流水线流程图

```
开发者 push 代码
      │
      ▼
┌──────────────┐
│   GitLab     │ ── 触发 Webhook ──▶ Jenkins
│  代码评审     │
│  MR/PR       │
└──────────────┘
      │
      ▼
┌──────────────┐     ┌──────────────┐
│  编译构建     │ ──▶ │  单元测试     │
│  Maven/Go    │     │  JUnit/Test  │
└──────────────┘     └──────┬───────┘
                            │
                     ┌──────▼───────┐
                     │  SonarQube   │
                     │  代码扫描     │
                     │  质量门禁     │
                     └──────┬───────┘
                            │ PASS
                     ┌──────▼───────┐
                     │  Docker构建  │
                     │  镜像构建     │
                     └──────┬───────┘
                            │
                     ┌──────▼───────┐
                     │  Harbor推送  │
                     │  镜像存储     │
                     └──────┬───────┘
                            │
                     ┌──────▼───────┐
                     │  Trivy扫描   │
                     │  安全检查     │
                     └──────┬───────┘
                            │ PASS
                     ┌──────▼───────┐
                     │  Staging部署 │
                     │  自动验证     │
                     └──────┬───────┘
                            │ OK
                     ┌──────▼───────┐
                     │  人工审批     │
                     └──────┬───────┘
                            │ APPROVE
                     ┌──────▼───────┐
                     │  Production  │
                     │  滚动更新     │
                     └──────┬───────┘
                            │
                     ┌──────▼───────┐
                     │  健康检查     │── FAIL ──▶ 自动回滚
                     └──────┬───────┘
                            │ PASS
                     ┌──────▼───────┐
                     │  部署完成     │
                     │  通知开发者   │
                     └──────────────┘
```

---

## 十一、项目文件清单

```
enterprise-cicd-pipeline/
├── scripts/
├── configs/                 # 配置文件(gitlab-ci/Dockerfile/Helm/Terraform/Ansible)
├── tests/                  # 部署验证测试
│   (实际脚本见项目根目录 scripts/01-k8s/ 至 scripts/10-security/)
│   ├── install_gitlab.sh
│   (实际脚本见项目根目录 scripts/01-k8s/ 至 scripts/10-security/)
│   ├── install_jenkins.sh
│   (实际脚本见项目根目录 scripts/01-k8s/ 至 scripts/10-security/)
│   ├── install_sonarqube.sh
│   ├── install_argocd.sh
│   ├── setup_webhook.sh
│   └── canary_promotion.sh
├── templates/
│   ├── .gitlab-ci.yml              # CI/CD标准模板
│   ├── Dockerfile                  # Dockerfile模板
│   ├── Jenkinsfile                 # Jenkins Pipeline
│   └── shared-library/
│       └── vars/enterprisePipeline.groovy
├── k8s/
│   ├── base/
│   │   ├── deployment.yaml
│   │   ├── service.yaml
│   │   ├── hpa.yaml
│   │   └── pdb.yaml
│   ├── overlays/
│   │   ├── staging/
│   │   └── production/
│   └── argocd-application.yaml
├── sonarqube/
│   └── quality-gate.json
└── README.md
```

---

> 本项目基于官方文档、技术博客和社区实践编写
> [架构说明] 本项目同时展示GitLab CI和Jenkins两种CI方案，实际生产中通常二选一。
> GitLab CI适合GitLab生态，Jenkins适合多工具集成场景。根据团队技术栈选择即可。
> 涵盖: Jenkins/GitLab CI, SonarQube, Harbor, ArgoCD, K8s部署, 金丝雀发布

---

## 真实故障案例深度分析

### 案例1: Jenkins Agent离线导致构建排队

**故障现象**: Jenkins构建任务全部排队，Build Queue显示"waiting for available agent"

**排查过程**:
```bash
# 查看Agent状态
kubectl get pods -n jenkins -l jenkins/agent-type=slave
# jenkins-agent-xxx   0/1     Terminating

# 查看Agent日志
kubectl logs jenkins-agent-xxx -n jenkins
# SEVERE: jenkins.util.proxy.ProxyException: java.net.SocketException: Connection reset
# Agent与Master连接中断
```

**解决方案**:
```bash
# 1. 配置Agent自动重连
# Jenkins → Manage Jenkins → Manage Nodes → Agent配置
# Remote FS Root: /home/jenkins
# Launch method: Kubernetes Pod Template
# Reconnect delay: 10s
# Max retries: 10

# 2. 配置Pod资源限制防止OOM
apiVersion: v1
kind: Pod
metadata:
  labels:
    jenkins/agent-type: slave
spec:
  containers:
  - name: jnlp
    resources:
      requests:
        cpu: 500m
        memory: 512Mi
      limits:
        cpu: "2"
        memory: 2Gi
```

### 案例2: SonarQube扫描超时

**故障现象**: Jenkins Pipeline中SonarQube扫描步骤超时

**排查过程**:
```bash
# 查看SonarQube日志
kubectl logs sonarqube-xxx -n sonarqube | grep -i "timeout"
# ERROR: SonarQube is not responding within 600000ms

# 查看资源使用
kubectl top pod sonarqube-xxx -n sonarqube
# CPU: 3500m (接近limit 4000m)
# Memory: 6Gi (接近limit 8Gi)
```

**解决方案**:
```bash
# 1. 增加SonarQube资源
kubectl patch deployment sonarqube -n sonarqube -p '{
  "spec": {
    "template": {
      "spec": {
        "containers": [{
          "name": "sonarqube",
          "resources": {
            "requests": {"cpu": "4", "memory": "8Gi"},
            "limits": {"cpu": "8", "memory": "16Gi"}
          }
        }]
      }
    }
  }
}'

# 2. 优化Jenkinsfile中的扫描配置
# stage('SonarQube') {
#   steps {
#     withSonarQubeEnv('SonarQube') {
#       sh 'mvn sonar:sonar -Dsonar.timeout=600 -Dsonar.threads=4'
#     }
#   }
# }
```

### 案例3: ArgoCD同步失败

**故障现象**: ArgoCD Application状态一直是OutOfSync，自动同步失败

**排查过程**:
```bash
# 查看Application状态
argocd app get my-app
# Status: OutOfSync
# Health: Degraded
# Message: "error creating resource: admission webhook...denied"

# 查看同步错误
argocd app sync my-app --dry-run
# Error: ValidationError(Deployment): unknown field "replicas" in apps/v1.Deployment
```

**解决方案**:
```bash
# 1. 修复YAML格式
# 错误: apiVersion: apps/v1 但使用了旧语法
# 修正: 确保YAML符合目标K8s版本的API

# 2. 配置ArgoCD自动修复
argocd app set my-app --sync-policy automated --auto-prune --self-heal

# 3. 配置健康检查
argocd app set my-app --health-check "Deployment/my-app"
```

### 案例4: GitLab Webhook丢失

**故障现象**: 代码推送后Jenkins没有自动触发构建

**排查过程**:
```bash
# 查看GitLab Webhook配置
# Settings → Webhooks → 最近触发记录
# 发现: "Delivery failed" 状态

# 查看Jenkins端日志
curl -v http://jenkins.internal:8080/generic-webhook-trigger/invoke
# HTTP/1.1 403 Forbidden
# Jenkins CSRF保护导致Webhook被拒
```

**解决方案**:
```bash
# 1. Jenkins关闭CSRF保护(仅内网)
# Manage Jenkins → Security → CSRF Protection → 取消勾选

# 2. 或使用API Token
# Manage Jenkins → API Tokens → 生成Token
# GitLab Webhook配置: http://jenkins:8080/generic-webhook-trigger/invoke?token=xxx

# 3. 配置重试机制
# GitLab Webhook → Enable SSL verification → Retry on failure (3次)
```

### 案例5: 镜像构建失败磁盘满

**故障现象**: Jenkins构建过程中Docker build失败，报"no space left on device"

**排查过程**:
```bash
# 查看Docker磁盘使用
docker system df
# Images: 150.5GB
# Containers: 20.3GB
# Build cache: 85.2GB
# 总计: 256GB (磁盘只有200GB!)
```

**解决方案**:
```bash
# 1. 清理Docker空间
docker system prune -af --volumes
docker builder prune -af

# 2. 配置自动清理(在Jenkinsfile中)
# post {
#   always {
#     sh 'docker system prune -f'
#   }
# }

# 3. 配置Docker daemon
cat > /etc/docker/daemon.json << EOF
{
  "storage-driver": "overlay2",
  "log-driver": "json-file",
  "log-opts": {"max-size": "10m", "max-file": "3"},
  "max-concurrent-downloads": 10,
  "max-concurrent-uploads": 5
}
EOF
```

### 案例6: Pipeline并发冲突

**故障现象**: 多个分支同时构建导致镜像标签冲突

**解决方案**:
```groovy
// Jenkinsfile - 使用唯一标签
pipeline {
  agent any
  stages {
    stage('Build') {
      steps {
        script {
          def tag = "${env.BRANCH_NAME}-${env.BUILD_NUMBER}-${System.currentTimeMillis()}"
          sh "docker build -t harbor.internal.com/myapp:${tag} ."
          sh "docker push harbor.internal.com/myapp:${tag}"
        }
      }
    }
  }
  // 使用lock step防止并发冲突
  options {
    lock(resource: 'docker-build', inversePrecedence: true)
  }
}
```

### 案例7: 凭据泄露到日志

**故障现象**: Jenkins构建日志中包含明文密码

**排查过程**:
```bash
# 查看构建日志
cat /var/jenkins_home/jobs/my-app/builds/123/log | grep -i password
# [Pipeline] sh
# docker login -u admin -P MyP@ssw0rd harbor.internal.com  # 密码明文!
```

**解决方案**:
```groovy
// 使用Credentials绑定
withCredentials([usernamePassword(
  credentialsId: 'harbor-credentials',
  usernameVariable: 'DOCKER_USER',
  passwordVariable: 'DOCKER_PASS'
)]) {
  sh "docker login -u \$DOCKER_USER -p \$DOCKER_PASS harbor.internal.com"
}

// 使用MaskPasswords插件
// Manage Jenkins → Global Tool Configuration → Mask passwords
```

### 案例8: 制品库磁盘满

**故障现象**: Harbor磁盘使用率100%，无法推送新镜像

**解决方案**:
```bash
# 1. 配置自动清理策略
# Harbor → Projects → my-project → Tag Retention
# 保留策略: 每个仓库最多保留10个Tag，保留30天

# 2. 手动清理
# 清理未引用的镜像
harbor admin delete --project my-project --untagged
# 或使用API
curl -X DELETE "http://harbor/api/v2.0/projects/my-project/repositories"   -u admin:${HARBOR_ADMIN_PASSWORD}

# 3. 配置垃圾回收
harbor gc --dry-run
harbor gc
```

---

## 高级性能调优参数

### Jenkins Master调优

```yaml
# Jenkins Helm values
controller:
  javaOpts: "-Xmx4g -XX:+UseG1GC -XX:MaxGCPauseMillis=200"
  resources:
    requests:
      cpu: "2"
      memory: 4Gi
    limits:
      cpu: "4"
      memory: 8Gi
  # 节点监控
  installPlugins:
    - kubernetes:latest
    - workflow-aggregator:latest
    - configuration-as-code:latest
  # JCasC配置
  JCasC:
    defaultConfig: true
    configScripts:
      kubernetes: |
        jenkins:
          clouds:
          - kubernetes:
              name: "kubernetes"
              serverUrl: "https://kubernetes.default"
              namespace: "jenkins"
              jenkinsUrl: "http://jenkins.jenkins:8080"
              jenkinsTunnel: "jenkins-agent.jenkins:50000"
              containerCapStr: "50"
              maxRequestsPerHostStr: "32"
```

### SonarQube调优

```yaml
# SonarQube Helm values
sonarqube:
  javaOpts: "-Xmx4g -XX:+UseG1GC"
  resources:
    requests:
      cpu: "4"
      memory: 8Gi
    limits:
      cpu: "8"
      memory: 16Gi
  # 数据库优化
  postgresql:
    resources:
      requests:
        cpu: "2"
        memory: 4Gi
  # 插件优化
  plugins:
    install:
      - sonar-java
      - sonar-javascript
      - sonar-python
```

### ArgoCD调优

```yaml
# ArgoCD Helm values
server:
  resources:
    requests:
      cpu: "1"
      memory: 1Gi
    limits:
      cpu: "2"
      memory: 2Gi
controller:
  resources:
    requests:
      cpu: "2"
      memory: 4Gi
    limits:
      cpu: "4"
      memory: 8Gi
  # 并发控制
  processors: 10
  # 缓存
  cache:
    enabled: true
    size: 500Mi
repoServer:
  resources:
    requests:
      cpu: "1"
      memory: 2Gi
  # 并发
  parallelismLimit: 10
```

---

## 灾备方案

### Jenkins备份

```bash
#!/bin/bash
# jenkins_backup.sh
JENKINS_HOME="/var/jenkins_home"
BACKUP_DIR="/data/jenkins-backup"
DATE=$(date +%Y%m%d)

# 备份关键目录(排除敏感数据或加密)
# [注意] secrets/目录包含master.key等敏感文件，备份后必须加密
tar czf ${BACKUP_DIR}/jenkins-${DATE}.tar.gz \
  ${JENKINS_HOME}/config.xml \
  ${JENKINS_HOME}/jobs/*/config.xml \
  ${JENKINS_HOME}/plugins/*.jpi \
  --exclude='*.log' \
  --exclude='secrets/'

# 上传到S3
aws s3 cp ${BACKUP_DIR}/jenkins-${DATE}.tar.gz s3://jenkins-backup/
```

### ArgoCD应用迁移

```bash
# 导出ArgoCD Application
argocd app get my-app -o yaml > my-app.yaml

# 修改后在新集群部署
kubectl apply -f my-app.yaml
```

---

## 详细成本估算

| 项目 | 自建 | 阿里云DevOps | GitHub Actions |
|------|------|------------|---------------|
| Jenkins Master(4C16G) | ¥3,000/月 | ¥2,000/月 | - |
| SonarQube(4C16G) | ¥3,000/月 | ¥2,000/月 | - |
| ArgoCD(2C8G) | ¥1,500/月 | ¥1,000/月 | - |
| Harbor(4C16G) | ¥3,000/月 | ¥2,000/月 | - |
| 运维人力(0.3人) | ¥6,000/月 | ¥1,000/月 | ¥0 |
| **月度总计** | **¥16,500** | **¥8,000** | **按量计费** |

---

## 全链路监控告警

```yaml
groups:
  - name: cicd
    rules:
      - alert: JenkinsBuildFailed
        expr: jenkins_builds_failed_total > 5
        for: 10m
        labels: { severity: warning }
      - alert: JenkinsJobQueueHigh
        expr: jenkins_queue_size_value > 10
        for: 5m
        labels: { severity: warning }
      - alert: SonarQubeQualityGateFailed
        expr: sonar_quality_gate_status{status="ERROR"} == 1
        for: 1m
        labels: { severity: warning }
      - alert: ArgoCDAppOutOfSync
        expr: argocd_app_info{sync_status="OutOfSync"} == 1
        for: 5m
        labels: { severity: warning }
      - alert: ArgoCDAppDegraded
        expr: argocd_app_info{health_status="Degraded"} == 1
        for: 2m
        labels: { severity: critical }
      - alert: HarborStorageFull
        expr: harbor_project_storage_bytes / harbor_project_storage_quota_bytes > 0.9
        for: 5m
        labels: { severity: warning }
```

---

## 完整运维SOP

### 日常巡检

```bash
#!/bin/bash
echo "===== CI/CD巡检 ====="
# Jenkins
kubectl get pods -n jenkins
curl -s http://jenkins:8080/api/json | jq '.jobs[] | {name, color}'
# SonarQube
kubectl get pods -n sonarqube
curl -s http://sonarqube:9000/api/system/status | jq '.status'
# ArgoCD
argocd app list
# Harbor
curl -s http://harbor/api/v2.0/systeminfo | jq '.storage'
```

### 紧急故障响应

```
Jenkins宕机: kubectl delete pod jenkins-xxx → 自动重建
SonarQube慢: 检查DB连接池 → 增加资源 → 重启
ArgoCD同步失败: 检查K8s权限 → 检查YAML语法
Harbor无法推送: 检查磁盘 → 清理镜像 → 检查TLS证书
```

### 版本升级SOP

```bash
# 1. 备份当前配置
helm get values jenkins -n jenkins > jenkins-values.yaml
# 2. 升级
helm upgrade jenkins jenkins/jenkins -n jenkins -f jenkins-values.yaml
# 3. 验证
kubectl get pods -n jenkins
```

---



## 踩坑记录

### Q1: Jenkins Pipeline中Docker build报permission denied
**原因**: Jenkins用户不在docker组
**解决**: usermod -aG docker jenkins && systemctl restart jenkins

### Q2: ArgoCD同步失败报"application spec is invalid"
**原因**: Kustomize overlay中引用了不存在的base资源
**解决**: 检查kustomization.yaml中的resources路径

### Q3: SonarQube扫描报"not enough memory"
**原因**: SonarQube默认JVM内存不足
**解决**: 增加SONAR_JAVA_OPTS=-Xmx4g参数

### Q4: GitLab CI Runner报"TLS handshake timeout"
**原因**: Runner与GitLab服务器网络不稳定
**解决**: 配置runner使用本地镜像缓存

### Q5: Trivy扫描报大量CVE但都是base image问题
**原因**: 基础镜像过旧
**解决**: 定期更新基础镜像版本，使用distroless镜像

> 涵盖: Jenkins + SonarQube + ArgoCD + Harbor + GitLab + K8s
> 适用于: 企业级CI/CD全链路建设
## Jenkins高可用方案

### 问题: Jenkins单点故障

Jenkins单节点部署，宕机则所有CI/CD流水线中断。

### 方案A: Kubernetes Deployment (推荐)

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: jenkins
  namespace: jenkins
spec:
  replicas: 1  # 单副本+PVC快速恢复，Jenkins不支持多实例共享数据
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 1
  selector:
    matchLabels:
      app: jenkins
  template:
    spec:
      containers:
        - name: jenkins
          image: jenkins/jenkins:lts-jdk17
          ports:
            - containerPort: 8080
            - containerPort: 50000
          volumeMounts:
            - name: jenkins-home
              mountPath: /var/jenkins_home
      volumes:
        - name: jenkins-home
          persistentVolumeClaim:
            claimName: jenkins-pvc
```

注意: Jenkins本身不支持多实例共享同一数据目录，HA方案主要保证快速恢复而非负载均衡。
实际建议: 使用单副本 + PVC持久化 + 快速重启策略，或迁移到Tekton/ArgoCD Workflows。

### 方案B: 堡垒机快速恢复

Jenkins宕机后:
1. kubectl delete pod jenkins-xxx (K8s自动重建)
2. 或 systemctl restart jenkins (物理机)
3. 恢复时间: 30秒-2分钟

Jenkins配置和流水线定义在Git中，重建后可自动恢复。
