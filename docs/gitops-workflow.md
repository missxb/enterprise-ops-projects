# ArgoCD GitOps工作流

## Application CRD示例

```yaml
# argocd-apps/production.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: user-service
  namespace: argocd
  # 生产环境开启自动同步和自愈
  annotations:
    argocd.argoproj.io/sync-wave: "1"
spec:
  project: production
  source:
    repoURL: https://gitlab.internal.com/platform/user-service.git
    targetRevision: main
    path: deploy/overlays/production
    kustomize:
      images:
        - harbor.internal.com/production/user-service:latest
  destination:
    server: https://kubernetes.default.svc
    namespace: production
  syncPolicy:
    automated:
      prune: true        # 删除Git中已移除的资源
      selfHeal: true     # 自动修复手动变更
    syncOptions:
      - CreateNamespace=true
      - PrunePropagationPolicy=foreground
    retry:
      limit: 3
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
  # [修复] ArgoCD Application spec中不存在healthChecks字段
  # 健康检查由ArgoCD自动处理，无需手动配置
```

## ApplicationSet(批量管理)

```yaml
# argocd-apps/appset-production.yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: microservices
  namespace: argocd
spec:
  generators:
    - list:
        elements:
          - name: user-service
            path: services/user-service
          - name: order-service
            path: services/order-service
          - name: payment-service
            path: services/payment-service
  template:
    metadata:
      name: '{{name}}'
    spec:
      project: production
      source:
        repoURL: https://gitlab.internal.com/platform/microservices.git
        targetRevision: main
        path: '{{path}}/deploy/overlays/production'
      destination:
        server: https://kubernetes.default.svc
        namespace: production
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
```

## Git工作流

```
开发者提交 → GitLab MR → CI构建镜像 → 推送Harbor
                                          ↓
                                   ArgoCD检测变更
                                          ↓
                                   同步到Staging → 人工审批
                                          ↓
                                   同步到Production
```

## 常用命令

```bash
# 查看同步状态
argocd app get user-service

# 手动同步
argocd app sync user-service

# 回滚
argocd app history user-service
argocd app rollback user-service 1

# 查看差异
argocd app diff user-service
```

## ApplicationSet高级Generator

### Git Generator
```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: microservices
spec:
  generators:
  - git:
      repoURL: https://github.com/org/k8s-manifests
      revision: main
      directories:
      - path: apps/*
  template:
    spec:
      project: default
      source:
        repoURL: https://github.com/org/k8s-manifests
        targetRevision: main
        path: '{{path}}'
      destination:
        server: https://kubernetes.default.svc
        namespace: '{{path.basename}}'
```

### Cluster Generator（多集群管理）
```yaml
  generators:
  - clusters:
      selector:
        matchLabels:
          env: production
```

### Matrix Generator（组合Git+Cluster）
```yaml
  generators:
  - matrix:
      generators:
      - git:
          repoURL: https://github.com/org/manifests
          revision: main
          directories:
          - path: apps/*
      - clusters:
          selector:
            matchLabels:
              env: production
```

## 多环境管理

### Kustomize Overlays
```
├── base/                    # 共享资源
│   ├── deployment.yaml
│   ├── service.yaml
│   └── kustomization.yaml
├── overlays/
│   ├── dev/                 # 开发环境
│   │   ├── kustomization.yaml  # replicas: 1, 小资源
│   │   └── patches/
│   ├── staging/             # 预发布环境
│   │   ├── kustomization.yaml  # replicas: 2, 中等资源
│   │   └── patches/
│   └── production/          # 生产环境
│       ├── kustomization.yaml  # replicas: 3, 完整资源+HPA
│       └── patches/
```

### Helm Values覆盖
```bash
# 不同环境使用不同values文件
helm install app -f values-base.yaml -f values-prod.yaml
```

## Secret管理方案

| 方案 | 原理 | 适用场景 |
|------|------|----------|
| External Secrets Operator | 从云KMS/HashiCorp Vault同步 | 已有Vault/KMS |
| Sealed Secrets | K8s加密后提交Git | 简单场景 |
| SOPS + KMS | 文件级加密 | GitOps工作流 |
| Vault Agent | 动态Secret注入 | 高安全要求 |

### External Secrets Operator示例
```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: app-secrets
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault-backend
    kind: SecretStore
  target:
    name: app-secrets
  data:
  - secretKey: db-password
    remoteRef:
      key: secret/data/app
      property: db-password
```
