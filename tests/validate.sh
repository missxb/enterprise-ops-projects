#!/bin/bash
# 部署验证测试脚本 v4
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

PASS=0
FAIL=0

check() {
  local name="$1"
  local cmd="$2"
  if eval "$cmd" >/dev/null 2>&1; then
    echo "  ✅ $name"
    PASS=$((PASS+1))
  else
    echo "  ❌ $name"
    FAIL=$((FAIL+1))
  fi
}

echo "=== 企业级运维项目集 验证测试 ==="
echo "仓库路径: $REPO_DIR"

echo "--- 1. 文档完整性 ---"
for f in "$REPO_DIR"/0*.md; do
  check "$(basename $f .md)" "test -s $f"
done

echo "--- 2. 脚本可用性 ---"
for f in "$REPO_DIR"/scripts/*/*.sh; do
  check "$(basename $f)" "test -x $f"
done

echo "--- 3. 配置完整性 ---"
check ".gitlab-ci.yml" "test -s $REPO_DIR/configs/.gitlab-ci.yml"
check "Dockerfile" "test -s $REPO_DIR/configs/Dockerfile"
check "Helm _helpers" "test -s $REPO_DIR/configs/helm/app/templates/_helpers.tpl"
check "Helm deployment" "test -s $REPO_DIR/configs/helm/app/templates/deployment.yaml"
check "Terraform" "test -s $REPO_DIR/configs/terraform/main.tf"
check ".env.example" "test -s $REPO_DIR/.env.example"
check "CHANGELOG" "test -s $REPO_DIR/CHANGELOG.md"
check ".gitignore" "test -s $REPO_DIR/.gitignore"

echo "--- 4. 脚本质量 ---"
check "set -euo pipefail" "grep -rq 'set -euo pipefail' $REPO_DIR/scripts/*/*.sh"
check "umask 077" "grep -rq 'umask 077' $REPO_DIR/scripts/*/*.sh"

echo "--- 5. 安全检查 ---"
check "无硬编码密码" "! grep -rq 'Admin@2024\\|password123\\|Repl@Pass\\|K8sHA2024\\|root123\\|NginxHA2024' $REPO_DIR/*.md $REPO_DIR/scripts/*/*.sh 2>/dev/null | grep -v 'changeme\\|占位符\\|openssl\\|sed.*password' | grep -q ."
check "无only残留" "! grep -q 'only:' $REPO_DIR/02-*.md 2>/dev/null"
check "Helm resources正确" "grep -q 'resources:' $REPO_DIR/configs/helm/app/templates/deployment.yaml && ! grep -A1 'resources:' $REPO_DIR/configs/helm/app/templates/deployment.yaml | grep -q 'readinessProbe'"

echo "--- 6. 版本一致性 ---"
check "K8s 1.28" "grep -q '1.28' $REPO_DIR/README.md"
check "Harbor 2.10" "grep -q '2.10' $REPO_DIR/README.md"

echo ""
echo "=============================="
echo "通过: $PASS  失败: $FAIL"
echo "=============================="

if [ "$FAIL" -eq 0 ]; then
  echo "🎉 全部检查通过!"
else
  echo "⚠️ 有 $FAIL 项未通过"
fi
exit $FAIL
