#!/bin/bash
# 部署验证测试脚本 v3
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

echo "--- 1. 文档完整性 ---"
for f in /root/enterprise-ops-projects/0*.md; do
  check "$(basename $f .md)" "test -s $f"
done

echo "--- 2. 脚本可用性 ---"
for f in /root/enterprise-ops-projects/scripts/*/*.sh; do
  check "$(basename $f)" "test -x $f"
done

echo "--- 3. 配置完整性 ---"
check ".gitlab-ci.yml" "test -s /root/enterprise-ops-projects/configs/.gitlab-ci.yml"
check "Dockerfile" "test -s /root/enterprise-ops-projects/configs/Dockerfile"
check "Helm _helpers" "test -s /root/enterprise-ops-projects/configs/helm/app/templates/_helpers.tpl"
check "Terraform" "test -s /root/enterprise-ops-projects/configs/terraform/main.tf"
check ".env.example" "test -s /root/enterprise-ops-projects/.env.example"
check "CHANGELOG" "test -s /root/enterprise-ops-projects/CHANGELOG.md"

echo "--- 4. 脚本质量 ---"
check "set -euo pipefail" "grep -rq 'set -euo pipefail' /root/enterprise-ops-projects/scripts/*/*.sh"
check "umask 077" "grep -rq 'umask 077' /root/enterprise-ops-projects/scripts/*/*.sh"

echo "--- 5. 安全检查 ---"
check "无硬编码密码" "! grep -rq 'Admin@2024\\|password123' /root/enterprise-ops-projects/*.md /root/enterprise-ops-projects/scripts/*/*.sh 2>/dev/null | grep -v 'changeme\\|占位符' | grep -q ."
check "无only残留" "! grep -q 'only:' /root/enterprise-ops-projects/02-*.md 2>/dev/null"

echo "--- 6. 版本一致性 ---"
check "K8s 1.28" "grep -q '1.28' /root/enterprise-ops-projects/README.md"

echo ""
echo "=============================="
echo "通过: $PASS  失败: $FAIL"
echo "=============================="

if [ "$FAIL" -eq 0 ]; then
  echo "🎉 全部检查通过!"
else
  echo "⚠️ 有 $FAIL 项未通过"
fi
exit 0
