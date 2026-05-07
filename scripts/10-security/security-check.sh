#!/bin/bash
# 安全快速检查脚本(轻量级初筛)
# 完整审计请使用 compliance-check.sh (等保二级)
set -euo pipefail
umask 077

# === 日志配置 ===
LOG_DIR="/var/log/k8s-ops"
LOG_FILE="${LOG_DIR}/$(basename $0 .sh)-$(date +%Y%m%d).log"
mkdir -p ${LOG_DIR}

log() {
    local level=$1; shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${level}] $*" | tee -a ${LOG_FILE}
}

log_info() { log "INFO" "$@"; }
log_warn() { log "WARN" "$@"; }
log_error() { log "ERROR" "$@"; }
log_ok()   { log "OK"   "$@"; }

# 错误处理
trap 'log_error "脚本执行失败，行号: $LINENO"' ERR

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

log_info "========================================"
log_info " 安全快速检查(初筛)"
log_info " 完整审计: compliance-check.sh"
log_info "========================================"

log_info "--- 1. SSH安全 ---"
check "SSH密钥认证启用" "grep -v 'PubkeyAuthentication no' /etc/ssh/sshd_config | grep -q 'PubkeyAuthentication'"
warn "SSH密码认证已关闭" "grep -q 'PasswordAuthentication no' /etc/ssh/sshd_config"
warn "SSH root登录受限" "grep -q 'PermitRootLogin prohibit-password' /etc/ssh/sshd_config"
warn "SSH使用非默认端口" "grep -E '^Port [0-9]+' /etc/ssh/sshd_config 2>/dev/null | grep -qv 'Port 22'"

log_info "--- 2. 系统安全 ---"
check "/etc/shadow权限正确" "[ \$(stat -c %a /etc/shadow) = '000' ] || [ \$(stat -c %a /etc/shadow) = '600' ]"
check "/etc/passwd权限正确" "[ \$(stat -c %a /etc/passwd) = '644' ]"
check "/root目录权限正确" "[ \$(stat -c %a /root) = '700' ]"
warn "审计服务运行" "systemctl is-active auditd 2>/dev/null"
warn "fail2ban运行" "systemctl is-active fail2ban 2>/dev/null"

log_info "--- 3. 网络安全 ---"
warn "防火墙状态(K8s节点需关闭)" "systemctl is-active firewalld 2>/dev/null || iptables -L -n | grep -q 'DROP\|REJECT'"
warn "SSH监听非所有接口" "! ss -tlnp | grep -q ':22 .*0.0.0.0\|:22 .*::'"

log_info "--- 4. 内核参数 ---"
if systemctl is-active kubelet >/dev/null 2>&1; then
  warn "IP转发(K8s节点应开启)" "[ \$(sysctl -n net.ipv4.ip_forward) = '1' ]"
else
  check "IP转发关闭(非K8s)" "[ \$(sysctl -n net.ipv4.ip_forward 2>/dev/null) = '0' ]"
fi
check "SYN cookie启用" "[ \$(sysctl -n net.ipv4.tcp_syncookies 2>/dev/null) = '1' ]"
check "ICMP重定向禁用" "[ \$(sysctl -n net.ipv4.conf.all.accept_redirects 2>/dev/null) = '0' ]"

log_info "--- 5. 异常进程/端口 ---"
warn "无异常LISTEN端口" "[ \$(ss -tlnp 2>/dev/null | grep -cv '127.0.0.1\|::1' || echo 0) -lt 20 ]"
warn "无异常cron任务" "[ \$(crontab -l 2>/dev/null | grep -cv '^#\|^$' || echo 0) -lt 10 ]"

echo ""
log_info "========================================"
log_info " 通过: $PASS  失败: $FAIL  警告: $WARN"
log_info "========================================"
log_info " 提示: 失败项需立即修复，警告项需人工确认"
log_info "========================================"

exit $FAIL
