#!/bin/bash
# Ansible批量部署脚本
set -euo pipefail
umask 077

INVENTORY="${1:?用法: $0 <inventory文件> [playbook]}"
PLAYBOOK="${2:-site.yml}"

echo "=== Ansible批量部署 ==="
echo "Inventory: ${INVENTORY}"
echo "Playbook: ${PLAYBOOK}"

# 检查inventory
if [ ! -f "${INVENTORY}" ]; then
  echo "❌ Inventory文件不存在: ${INVENTORY}"
  exit 1
fi

# 执行ansible-playbook
ansible-playbook -i "${INVENTORY}" "${PLAYBOOK}" \
  --ask-vault-pass \
  -v

echo "✅ 部署完成"
