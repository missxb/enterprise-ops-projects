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
  # 健康检查
  healthChecks:
    - apiVersion: apps/v1
      kind: Deployment
      name: user-service
      namespace: production
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
