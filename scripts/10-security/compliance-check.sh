#!/bin/bash
# 等保合规检查脚本(二级)
set -euo pipefail
umask 077

PASS=0
FAIL=0
WARN=0

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

warn() {
  local name="$1"
  local cmd="$2"
  if eval "$cmd" >/dev/null 2>&1; then
    echo "  ✅ $name"
    PASS=$((PASS+1))
  else
    echo "  ⚠️  $name"
    WARN=$((WARN+1))
  fi
}

echo "========================================"
echo " 等保二级合规检查"
echo "========================================"

echo "--- 1. 身份鉴别 ---"
check "密码复杂度" "grep -q 'minlen.*8\\|pam_pwquality' /etc/pam.d/system-auth 2>/dev/null || grep -q 'minlen' /etc/security/pwquality.conf 2>/dev/null"
check "登录失败锁定" "grep -q 'pam_faillock\\|pam_tally2' /etc/pam.d/system-auth 2>/dev/null"
warn "SSH密钥认证(默认开启)" "grep -v 'PubkeyAuthentication no' /etc/ssh/sshd_config | grep -q 'PubkeyAuthentication'"
warn "SSH密码认证关闭" "grep -q 'PasswordAuthentication no' /etc/ssh/sshd_config"

echo "--- 2. 访问控制 ---"
check "最小权限原则" "[ \$(stat -c %a /etc/shadow) = '000' ] || [ \$(stat -c %a /etc/shadow) = '600' ]"
check "重要文件权限" "[ \$(stat -c %a /etc/passwd) = '644' ]"
check "umask设置" "grep -q 'umask 027\\|umask 077' /etc/profile 2>/dev/null || grep -q 'umask 027\\|umask 077' /etc/bashrc 2>/dev/null"

echo "--- 3. 安全审计 ---"
warn "审计服务运行" "systemctl is-active auditd 2>/dev/null"
warn "审计规则配置" "[ -f /etc/audit/rules.d/audit.rules ] && [ -s /etc/audit/rules.d/audit.rules ]"

echo "--- 4. 网络安全 ---"
warn "防火墙状态(K8s节点需关闭)" "systemctl is-active firewalld 2>/dev/null || iptables -L -n | grep -q 'DROP\\\\|REJECT'"
warn "SSH端口非默认" "grep -E '^Port [0-9]+' /etc/ssh/sshd_config 2>/dev/null | grep -qv 'Port 22'"
# K8s节点需开启IP转发，非K8s节点需关闭
if systemctl is-active kubelet >/dev/null 2>&1; then
  warn "IP转发(K8s节点应开启)" "[ \$(sysctl -n net.ipv4.ip_forward) = '1' ]"
else
  check "IP转发关闭(非K8s)" "[ \$(sysctl -n net.ipv4.ip_forward 2>/dev/null) = '0' ]"
fi

echo "--- 5. 入侵防范 ---"
warn "fail2ban运行" "systemctl is-active fail2ban 2>/dev/null"
warn "日志集中收集" "systemctl is-active filebeat 2>/dev/null || ls /var/log/messages >/dev/null 2>&1"

echo ""
echo "========================================"
echo " 通过: $PASS  失败: $FAIL  警告: $WARN"
echo "========================================"

exit $FAIL
