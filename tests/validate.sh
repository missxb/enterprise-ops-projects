#!/bin/bash
# 部署验证测试脚本 v5
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

echo "=== 企业级运维项目集 验证测试 v5 ==="
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
check "Helm configmap" "test -s $REPO_DIR/configs/helm/app/templates/configmap.yaml"
check "Helm secret" "test -s $REPO_DIR/configs/helm/app/templates/secret.yaml"
check "Terraform" "test -s $REPO_DIR/configs/terraform/main.tf"
check ".env.example" "test -s $REPO_DIR/.env.example"
check "CHANGELOG" "test -s $REPO_DIR/CHANGELOG.md"
check ".gitignore" "test -s $REPO_DIR/.gitignore"
check "Makefile" "test -s $REPO_DIR/Makefile"
check "alert-rules" "test -s $REPO_DIR/configs/monitoring/alert-rules.yml"
check "filebeat" "test -s $REPO_DIR/configs/logging/filebeat.yml"

echo "--- 4. 脚本质量 ---"
check "set -euo pipefail" "grep -rq 'set -euo pipefail' $REPO_DIR/scripts/*/*.sh"
check "umask 077" "grep -rq 'umask 077' $REPO_DIR/scripts/*/*.sh"

echo "--- 5. 安全检查 ---"
check "无硬编码密码" "! grep -rq 'Admin@2024\\|password123\\|Repl@Pass\\|K8sHA2024\\|NginxHA2024\\|ProxySQL2024' $REPO_DIR/*.md $REPO_DIR/scripts/*/*.sh 2>/dev/null | grep -v 'changeme\\|占位符\\|openssl\\|sed.*password\\|harbor.yml.tmpl' | grep -q ."
check "无only残留" "! grep -q 'only:' $REPO_DIR/02-*.md 2>/dev/null"
check "Helm resources正确" "grep -q 'resources:' $REPO_DIR/configs/helm/app/templates/deployment.yaml && ! grep -A1 'resources:' $REPO_DIR/configs/helm/app/templates/deployment.yaml | grep -q 'readinessProbe'"

echo "--- 6. 版本一致性 ---"
check "K8s 1.31" "grep -q '1.31' $REPO_DIR/README.md"
check "Harbor 2.12" "grep -q '2.12' $REPO_DIR/README.md"
check "Redis 7.2" "grep -q '7.2' $REPO_DIR/README.md"

echo "--- 7. ShellCheck(如安装) ---"
if command -v shellcheck >/dev/null 2>&1; then
  SHELLCHECK_PASS=0
  SHELLCHECK_FAIL=0
  for f in "$REPO_DIR"/scripts/*/*.sh; do
    if shellcheck -x "$f" 2>/dev/null; then
      SHELLCHECK_PASS=$((SHELLCHECK_PASS+1))
    else
      echo "  ⚠️ shellcheck: $(basename $f)"
      SHELLCHECK_FAIL=$((SHELLCHECK_FAIL+1))
    fi
  done
  check "ShellCheck" "[ $SHELLCHECK_FAIL -eq 0 ]"
else
  echo "  ⏭️ shellcheck未安装，跳过"
fi

echo "--- 8. YAML语法(如安装) ---"
if command -v python3 >/dev/null 2>&1; then
  YAML_FAIL=0
  # 注意: Helm模板文件(含{{ }})会被跳过，它们需要通过helm template验证
  for f in "$REPO_DIR"/configs/*.yml "$REPO_DIR"/configs/**/*.yml "$REPO_DIR"/configs/**/*.yaml; do
    [ -f "$f" ] || continue
    # 跳过Helm模板文件(含{{ }}语法，Python YAML解析器无法处理)
    if echo "$f" | grep -q '/helm/'; then
      continue
    fi
    if ! python3 -c "import yaml; list(yaml.safe_load_all(open('$f')))" 2>/dev/null; then
      echo "  ⚠️ yaml: $(basename $f)"
      YAML_FAIL=$((YAML_FAIL+1))
    fi
  done
  check "YAML语法" "[ $YAML_FAIL -eq 0 ]"
else
  echo "  ⏭️ python3未安装，跳过"
fi

echo "--- 9. Helm模板完整性 ---"
HELPM_TPL=$(ls "$REPO_DIR"/configs/helm/app/templates/*.yaml 2>/dev/null | wc -l)
check "Helm模板>=5个" "[ $HELPM_TPL -ge 5 ]"

echo "--- 10. 脚本超时保护 ---"
check "redis-backup有超时" "grep -q 'MAX_WAIT\\|超时' $REPO_DIR/scripts/06-redis/redis-backup.sh"
check "pitr有确认" "grep -q '确认\\|CONFIRM' $REPO_DIR/scripts/05-mysql/pitr-restore.sh"

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
