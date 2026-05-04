#!/bin/bash
# 安全加固检查脚本
set -euo pipefail
umask 077

echo "=== 安全加固检查 ==="

echo "1. SSH配置检查..."
grep -E "^PermitRootLogin|^PasswordAuthentication|^Port" /etc/ssh/sshd_config || echo "  ⚠️ SSH配置未找到"

echo "2. 防火墙状态(K8s节点需关闭firewalld)..."
if firewall-cmd --state 2>/dev/null; then
  echo "  ⚠️ firewalld运行中，K8s节点建议关闭"
else
  echo "  ✅ firewalld已关闭"
fi

echo "3. fail2ban状态..."
systemctl is-active fail2ban || echo "  ⚠️ fail2ban未运行"

echo "4. 内核参数检查..."
sysctl net.ipv4.ip_forward net.ipv4.conf.all.rp_filter 2>/dev/null || echo "  ⚠️ 内核参数未设置"

echo "5. 文件权限检查..."
ls -la /etc/shadow /etc/passwd

echo "6. 审计日志..."
systemctl is-active auditd || echo "  ⚠️ auditd未运行"

echo "✅ 安全检查完成"
