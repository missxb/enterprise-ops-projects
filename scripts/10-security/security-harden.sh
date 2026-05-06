#!/bin/bash
# 服务器安全加固生产级脚本(等保二级)
# 依赖: ssh(节点间免密), yum/apt
# 前置: 以root权限运行, 已备份SSH配置
set -euo pipefail
umask 077

NODES="${NODES:?请设置需要加固的节点列表(空格分隔)}"
SSH_PORT="${SSH_PORT:-22}"
ADMIN_IP="${ADMIN_IP:?请设置管理IP白名单}"

echo "=== 服务器安全加固(等保二级) ==="
echo "节点: ${NODES}"
echo "管理IP: ${ADMIN_IP}"

for node in ${NODES}; do
  echo ""
  echo ">>> 加固节点: ${node}"

  ssh root@${node} bash << 'HARDENING_EOF'

# 1. 禁用root远程登录(保留sudo)
echo ">>> 1. 配置SSH安全"
sed -E -i 's/^#?PermitRootLogin yes/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
sed -E -i 's/^#?PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config

# 2. 配置SSH端口和白名单(生产环境修改默认端口)
# sed -i 's/^#Port 22/Port 2222/' /etc/ssh/sshd_config
# sed -i '/^Port/a AllowUsers admin deploy' /etc/ssh/sshd_config

systemctl restart sshd

# 3. 内核安全参数
echo ">>> 2. 配置内核安全参数"
cat > /etc/sysctl.d/99-security.conf << 'SYSCTL'
# 禁用IP转发(非K8s节点)
# net.ipv4.ip_forward = 0

# 防止SYN攻击
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 2048
net.ipv4.tcp_synack_retries = 2

# 禁用ICMP重定向
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0

# 禁用源路由
net.ipv4.conf.all.accept_source_route = 0

# 启用地址空间随机化
kernel.randomize_va_space = 2

# 限制core dump
fs.suid_dumpable = 0

# 文件系统只读挂载选项(生产环境)
# /dev/shm -> nosuid,nodev,noexec

# 限制dmesg访问
kernel.dmesg_restrict = 1

# 限制性能事件
kernel.perf_event_paranoid = 3
SYSCTL
sysctl -p /etc/sysctl.d/99-security.conf

# 4. 密码策略
echo ">>> 3. 配置密码策略"
sed -i 's/^PASS_MAX_DAYS.*/PASS_MAX_DAYS   90/' /etc/login.defs
sed -i 's/^PASS_MIN_DAYS.*/PASS_MIN_DAYS   7/' /etc/login.defs
sed -i 's/^PASS_MIN_LEN.*/PASS_MIN_LEN    12/' /etc/login.defs

# 5. 文件权限加固
echo ">>> 4. 加固文件权限"
chmod 600 /etc/shadow
chmod 644 /etc/passwd
chmod 700 /root
chmod 600 /etc/ssh/sshd_config
chmod 700 /etc/cron.d
chmod 700 /etc/cron.daily

# 6. 审计日志(等保要求)
echo ">>> 5. 配置审计日志"
yum install -y audit
systemctl enable auditd
systemctl start auditd

# 添加审计规则(临时+持久化)
auditctl -w /etc/passwd -p wa -k identity
auditctl -w /etc/shadow -p wa -k identity
auditctl -w /etc/sudoers -p wa -k sudoers
auditctl -w /var/log/secure -p wa -k logins

# 持久化审计规则(重启后仍生效)
cat > /etc/audit/rules.d/99-custom.rules << 'AUDITEOF'
-w /etc/passwd -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/sudoers -p wa -k sudoers
-w /var/log/secure -p wa -k logins
# [修复] 添加-e 2使审计规则不可变(需要重启才能修改，防止攻击者篡改)
-e 2
AUDITEOF
augenrules --load 2>/dev/null || true

# 7. 禁用不必要的服务
echo ">>> 6. 禁用不必要的服务"
for service in avahi-daemon cups bluetooth; do
  systemctl stop ${service} 2>/dev/null || true
  systemctl disable ${service} 2>/dev/null || true
done

# 8. 配置fail2ban(SSH暴力破解防护)
echo ">>> 7. 配置fail2ban"
yum install -y fail2ban 2>/dev/null || apt-get install -y fail2ban 2>/dev/null || true
cat > /etc/fail2ban/jail.local << 'F2BEOF'
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1 ADMIN_IP_PLACEHOLDER
bantime = 3600
findtime = 600
maxretry = 5
backend = systemd

[sshd]
enabled = true
port = ssh
logpath = /var/log/secure
maxretry = 3
bantime = 86400
F2BEOF
# 注入管理IP白名单(防止Ansible控制机被封禁)
sed -i "s/ADMIN_IP_PLACEHOLDER/${ADMIN_IP}/" /etc/fail2ban/jail.local
systemctl enable fail2ban 2>/dev/null || true
systemctl start fail2ban 2>/dev/null || true

# 9. 配置防火墙(非K8s节点启用firewalld，K8s节点使用NetworkPolicy替代)
echo ">>> 8. 配置防火墙"

# K8s节点使用NetworkPolicy替代firewalld，跳过防火墙配置
if systemctl is-active kubelet &>/dev/null; then
  echo "  ℹ️  检测到K8s节点，跳过firewalld配置(使用NetworkPolicy)"
else
  # 非K8s节点: 启用firewalld
  systemctl enable firewalld
  systemctl start firewalld
  firewall-cmd --permanent --add-service=ssh
  firewall-cmd --permanent --add-port=80/tcp
  firewall-cmd --permanent --add-port=443/tcp
  # [修复] 添加数据库端口限制(仅允许内网访问)
  firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="10.10.0.0/16" port port="3306" protocol="tcp" accept'
  firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="10.10.0.0/16" port port="6379" protocol="tcp" accept'
  # 拒绝外部访问数据库端口
  firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="0.0.0.0/0" port port="3306" protocol="tcp" reject'
  firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="0.0.0.0/0" port port="6379" protocol="tcp" reject'
  firewall-cmd --reload
  echo "  防火墙已启用(非K8s节点)"
fi

# 10. SELinux策略
echo ">>> 9. 检查SELinux策略"
if [ -f /etc/selinux/config ]; then
  current=$(grep ^SELINUX= /etc/selinux/config | cut -d= -f2)
  if [ "$current" = "enforcing" ]; then
    echo "  ⚠️  等保三级要求SELinux=enforcing，但K8s节点需要permissive"
    echo "  ℹ️  K8s节点: 保持permissive(已由node-init.sh设置)"
    echo "  ℹ️  非K8s节点: 建议保持enforcing以满足等保要求"
  elif [ "$current" = "permissive" ]; then
    echo "  ℹ️  SELinux=permissive(K8s兼容模式)"
  fi
else
  echo "  ℹ️  未检测到SELinux配置(/etc/selinux/config不存在)，跳过"
fi

HARDENING_EOF

  echo "  ✅ ${node} 安全加固完成"
done

# Step 2: 验证加固效果
echo ""
echo ">>> 验证加固效果"
for node in ${NODES}; do
  echo "  ${node}:"
  ssh root@${node} "echo '  SSH配置:'; grep -E 'PermitRootLogin|PasswordAuthentication' /etc/ssh/sshd_config | head -3"
done

echo ""
echo "=== 安全加固完成 ==="
echo "  下一步: 运行 compliance-check.sh 验证等保合规"

# Step 3: 审计日志轮转(在远程节点配置，防止磁盘占满)
echo ""
echo ">>> Step 3: 配置审计日志轮转"
for node in ${NODES}; do
  ssh root@${node} bash << 'LOGROTATE_EOF'
cat > /etc/logrotate.d/audit << 'LOGROTATE'
/var/log/audit/*.log {
    daily
    rotate 30
    compress
    delaycompress
    missingok
    notifempty
    create 0600 root root
    postrotate
        /sbin/service auditd restart 2>/dev/null || true
    endscript
}
LOGROTATE
LOGROTATE_EOF
  echo "  ✅ ${node} 审计日志轮转已配置(保留30天)"
done
