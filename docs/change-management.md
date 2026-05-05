# 变更管理流程

## 变更分类
| 级别 | 描述 | 审批要求 | 执行窗口 |
|------|------|----------|----------|
| P1-紧急 | 生产故障修复 | 电话审批 | 随时 |
| P2-重要 | 功能变更/升级 | 技术负责人审批 | 维护窗口 |
| P3-一般 | 配置优化 | 团队审批 | 工作时间 |
| P4-低 | 文档/脚本 | 自审 | 随时 |

## 变更流程
1. **申请**: 提交变更申请(含回滚方案)
2. **评审**: 技术评审+风险评估
3. **审批**: 按级别审批
4. **准备**: 备份+回滚脚本+通知
5. **执行**: 灰度发布+监控
6. **验证**: 功能验证+性能验证
7. **关闭**: 文档更新+复盘

## 灰度发布策略
- K8s: 滚动更新(maxSurge=1, maxUnavailable=0)
- 数据库: 先从库后主库
- 中间件: 蓝绿部署/金丝雀发布

## 回滚决策树
1. 监控告警触发 → 自动回滚
2. 手动发现异常 → 30分钟内回滚
3. 回滚后验证 → 确认恢复
4. 回滚失败 → 启动应急预案

## 金丝雀发布详细实现

### 方案一: K8s原生滚动更新 + 人工验证
```yaml
# deployment-canary.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${SERVICE}-canary
spec:
  replicas: 1  # 金丝雀副本(少量流量)
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1        # 新版本最多多1个Pod
      maxUnavailable: 0  # 不允许不可用
  selector:
    matchLabels:
      app: ${SERVICE}
      track: canary
  template:
    metadata:
      labels:
        app: ${SERVICE}
        track: canary
    spec:
      containers:
      - name: ${SERVICE}
        image: harbor.internal.com/production/${SERVICE}:${CANARY_TAG}
        readinessProbe:
          httpGet:
            path: /healthz
            port: 8080
          initialDelaySeconds: 10
          periodSeconds: 5
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
          limits:
            cpu: 500m
            memory: 512Mi
```

### 金丝雀发布脚本
```bash
#!/bin/bash
# canary-deploy.sh - 金丝雀发布流程
set -euo pipefail

SERVICE="${1:?用法: $0 <service> <image-tag>}"
CANARY_TAG="${2:?请提供金丝雀版本tag}"
CANARY_WEIGHT="${CANARY_WEIGHT:-5}"  # 金丝雀流量比例(%)
CANARY_WAIT="${CANARY_WAIT:-300}"     # 观察时间(秒)
NAMESPACE="${NAMESPACE:-production}"
HARBOR="harbor.internal.com/production"

echo "=== 金丝雀发布: ${SERVICE} → ${CANARY_TAG} ==="

# Step 1: 部署金丝雀版本
echo ">>> Step 1: 部署金丝雀Pod(1副本)..."
kubectl set image deployment/${SERVICE}-canary \
  ${SERVICE}=${HARBOR}/${SERVICE}:${CANARY_TAG} \
  -n ${NAMESPACE} --record

# Step 2: 等待就绪
echo ">>> Step 2: 等待金丝雀Pod就绪..."
kubectl rollout status deployment/${SERVICE}-canary \
  -n ${NAMESPACE} --timeout=120s

# Step 3: 观察期(监控错误率)
echo ">>> Step 3: 观察期 ${CANARY_WAIT}秒..."
echo "  监控指标:"
echo "    - 错误率: curl -s 'http://prometheus:9090/api/v1/query?query=rate(http_requests_total{app="${SERVICE}",version="canary"}[5m])*100'"
echo "    - P99延迟: curl -s 'http://prometheus:9090/api/v1/query?query=histogram_quantile(0.99,rate(http_request_duration_seconds_bucket{app="${SERVICE}",version="canary"}[5m]))'"
echo ""
echo "  观察期间如有异常，执行回滚:"
echo "    kubectl rollout undo deployment/${SERVICE}-canary -n ${NAMESPACE}"
echo ""
echo "  等待 ${CANARY_WAIT}秒..."
sleep ${CANARY_WAIT}

# Step 4: 确认无异常后，滚动更新正式版本
echo ">>> Step 4: 全量发布..."
kubectl set image deployment/${SERVICE} \
  ${SERVICE}=${HARBOR}/${SERVICE}:${CANARY_TAG} \
  -n ${NAMESPACE} --record

kubectl rollout status deployment/${SERVICE} \
  -n ${NAMESPACE} --timeout=300s

# Step 5: 删除金丝雀Deployment
echo ">>> Step 5: 清理金丝雀..."
kubectl delete deployment ${SERVICE}-canary -n ${NAMESPACE} --ignore-not-found

echo "✅ 金丝雀发布完成: ${SERVICE}:${CANARY_TAG}"
```

### Prometheus告警规则(金丝雀监控)
```yaml
# canary-alerts.yml
groups:
- name: canary-release
  rules:
  - alert: CanaryHighErrorRate
    expr: rate(http_requests_total{version="canary",status=~"5.."}[5m]) / rate(http_requests_total{version="canary"}[5m]) > 0.05
    for: 2m
    labels:
      severity: critical
    annotations:
      summary: "金丝雀版本错误率超过5%"
  - alert: CanaryHighLatency
    expr: histogram_quantile(0.99, rate(http_request_duration_seconds_bucket{version="canary"}[5m])) > 1
    for: 2m
    labels:
      severity: warning
    annotations:
      summary: "金丝雀版本P99延迟超过1秒"
```

## 数据库变更管理(DDL审核)

### DDL审核流程
1. 开发提交DDL变更脚本
2. DBA审核(索引设计、锁表风险、数据量评估)
3. 在从库执行验证
4. 主库执行(维护窗口内)
5. 验证复制延迟和数据一致性

### DDL审核脚本
```bash
#!/bin/bash
# ddl-review.sh - DDL变更审核检查
set -euo pipefail

DDL_FILE="${1:?用法: $0 <ddl.sql文件>}"
MYSQL_CMD="mysql --defaults-extra-file=/etc/mysql/review.cnf"

echo "=== DDL审核检查: ${DDL_FILE} ==="

# 检查1: 是否包含DROP TABLE/DATABASE
if grep -iE 'DROP\s+(TABLE|DATABASE)' "${DDL_FILE}"; then
  echo "⚠️  包含DROP操作，需要DBA人工确认!"
  echo "  建议: 先RENAME TABLE做软删除"
fi

# 检查2: ALTER TABLE是否包含大表风险
if grep -iE 'ALTER\s+TABLE' "${DDL_FILE}"; then
  echo "⚠️  包含ALTER TABLE操作，请确认:"
  echo "  1. 表数据量(>100万行需pt-osc)"
  echo "  2. 是否会锁表"
  echo "  3. 建议使用pt-online-schema-change"
fi

# 检查3: 新建索引
if grep -iE 'ADD\s+(UNIQUE\s+)?INDEX|CREATE\s+(UNIQUE\s+)?INDEX' "${DDL_FILE}"; then
  echo "📝 包含新建索引，请确认:"
  echo "  1. 索引选择性(区分度)"
  echo "  2. 对写入性能的影响"
  echo "  3. 大表建议使用ALTER TABLE ... ALGORITHM=INPLACE"
fi

# 检查4: 编码变更
if grep -iE 'CHARACTER\s+SET|COLLATE' "${DDL_FILE}"; then
  echo "⚠️  包含字符集变更，可能影响全表!"
fi

echo ""
echo "审核完成。如需在生产环境执行:"
echo "  mysql --defaults-extra-file=/etc/mysql/prod.cnf < ${DDL_FILE}"
```
## 变更记录模板
- 变更编号:
- 变更级别:
- 变更内容:
- 影响范围:
- 回滚方案:
- 执行人:
- 审批人:
- 执行时间:
- 验证结果:
