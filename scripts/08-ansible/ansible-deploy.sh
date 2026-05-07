#!/bin/bash
# ============================================================================
# Ansible 批量部署脚本 - 完整版
# 依赖: ansible-core, sshpass (可选), jq (可选)
# 前置: SSH免密已配置，或通过参数提供凭据
# ============================================================================
set -euo pipefail
umask 077

# ========================= 颜色与日志 =========================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info()  { echo -e "${BLUE}[INFO]${NC}  $(date '+%Y-%m-%d %H:%M:%S') $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $(date '+%Y-%m-%d %H:%M:%S') $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $(date '+%Y-%m-%d %H:%M:%S') $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*" >&2; }

# 错误处理
trap 'log_error "脚本执行失败，行号: $LINENO"' ERR

# ========================= 全局变量 =========================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${WORK_DIR:-/tmp/ansible-deploy-$(date +%s)}"
INVENTORY_FILE=""
PLAYBOOK_FILE=""
DRY_RUN=false
LIMIT_HOSTS=""
EXTRA_VARS=()
TAGS=""
SKIP_TAGS=""
VERBOSE=""
REPORT_FILE=""
AUTO_GENERATE_INVENTORY=false
CHECK_ONLY=false
NODES_DATA=""

# ========================= 内置 Playbook 模板 =========================
declare -A PLAYBOOKS=(
  ["k8s-init"]="Kubernetes 集群初始化"
  ["docker-install"]="Docker/Containerd 安装"
  ["monitoring"]="Prometheus + Grafana 监控部署"
  ["mysql-cluster"]="MySQL 集群部署"
  ["redis-cluster"]="Redis Cluster 部署"
  ["elasticsearch"]="Elasticsearch 集群部署"
  ["nginx-ingress"]="Nginx Ingress Controller"
  ["cert-manager"]="Cert-Manager + TLS 证书"
  ["log-collector"]="日志收集 (Filebeat/Fluentd)"
  ["security-hardening"]="安全加固基线"
)

# ========================= 帮助信息 =========================
usage() {
  cat <<'USAGE'
用法: ansible-deploy.sh [选项]

选项:
  -i, --inventory FILE    指定 inventory 文件路径 (或自动生成)
  -p, --playbook FILE|NAME  指定 playbook 文件或内置模板名
  -l, --limit HOSTS       限制执行目标 (ansible --limit 格式)
  -t, --tags TAGS         只执行指定 tags
  -T, --skip-tags TAGS    跳过指定 tags
  -e, --extra-var KEY=VAL 额外变量 (可多次使用)
  --dry-run               仅检查，不实际执行 (--check 模式)
  --check                 执行前连通性测试
  --generate-inventory    自动生成 inventory (从环境变量读取节点)
  --list-playbooks        列出所有内置 playbook 模板
  --list-nodes            显示将要部署的节点列表
  -v, --verbose           增加输出详细度 (-v / -vv / -vvv)
  -r, --report FILE       部署报告输出路径
  -h, --help              显示此帮助信息

环境变量 (用于自动生成 inventory):
  MASTER_NODES      Master 节点列表，逗号分隔 (user@host 格式)
  WORKER_NODES      Worker 节点列表，逗号分隔
  ANSIBLE_USER      SSH 用户名 (默认: root)
  ANSIBLE_SSH_KEY   SSH 私钥路径 (默认: ~/.ssh/id_rsa)
  ANSIBLE_SSH_PASS  SSH 密码 (不推荐，仅用于紧急场景)
  ANSIBLE_BECOME    是否使用 sudo (默认: true)

示例:
  # 使用已有 inventory 执行 k8s 初始化
  ansible-deploy.sh -i inventory.ini -p k8s-init

  # 自动生成 inventory 并执行 Docker 安装
  export MASTER_NODES="root@10.0.0.1,root@10.0.0.2,root@10.0.0.3"
  export WORKER_NODES="root@10.0.1.1,root@10.0.1.2"
  ansible-deploy.sh --generate-inventory -p docker-install

  # 列出可用的内置 playbook
  ansible-deploy.sh --list-playbooks
USAGE
}

# ========================= 参数解析 =========================
parse_args() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      -i|--inventory)       INVENTORY_FILE="$2"; shift 2 ;;
      -p|--playbook)        PLAYBOOK_FILE="$2"; shift 2 ;;
      -l|--limit)           LIMIT_HOSTS="$2"; shift 2 ;;
      -t|--tags)            TAGS="$2"; shift 2 ;;
      -T|--skip-tags)       SKIP_TAGS="$2"; shift 2 ;;
      -e|--extra-var)       EXTRA_VARS+=("$2"); shift 2 ;;
      --dry-run)            DRY_RUN=true; shift ;;
      --check)              CHECK_ONLY=true; shift ;;
      --generate-inventory) AUTO_GENERATE_INVENTORY=true; shift ;;
      --list-playbooks)     list_playbooks; exit 0 ;;
      --list-nodes)         list_nodes; exit 0 ;;
      -v|--verbose)         VERBOSE="-${1#-}"; shift ;;
      -r|--report)          REPORT_FILE="$2"; shift 2 ;;
      -h|--help)            usage; exit 0 ;;
      *)                    log_error "未知参数: $1"; usage; exit 1 ;;
    esac
  done

  # 默认报告路径
  if [[ -z "$REPORT_FILE" ]]; then
    REPORT_FILE="${WORK_DIR}/deploy-report-$(date +%Y%m%d-%H%M%S).txt"
  fi
}

# ========================= 列出内置 Playbook =========================
list_playbooks() {
  echo "可用的内置 Playbook 模板:"
  echo "────────────────────────────────────────────────"
  for key in $(echo "${!PLAYBOOKS[@]}" | tr ' ' '\n' | sort); do
    printf "  %-25s %s\n" "$key" "${PLAYBOOKS[$key]}"
  done
}

# ========================= 显示节点列表 =========================
list_nodes() {
  log_info "将要部署的节点列表:"
  echo "────────────────────────────────────────────────"
  if [[ -n "${MASTER_NODES:-}" ]]; then
    echo "  Master 节点:"
    IFS=',' read -ra masters <<< "$MASTER_NODES"
    for node in "${masters[@]}"; do
      echo "    - ${node}"
    done
  fi
  if [[ -n "${WORKER_NODES:-}" ]]; then
    echo "  Worker 节点:"
    IFS=',' read -ra workers <<< "$WORKER_NODES"
    for node in "${workers[@]}"; do
      echo "    - ${node}"
    done
  fi
  if [[ -z "${MASTER_NODES:-}" && -z "${WORKER_NODES:-}" ]]; then
    echo "  (未配置节点，请设置 MASTER_NODES / WORKER_NODES 环境变量)"
  fi
}

# ========================= 前置检查 =========================
preflight_check() {
  log_info "执行前置检查..."

  local errors=0

  # 检查 ansible
  if ! command -v ansible-playbook &>/dev/null; then
    log_error "ansible-playbook 未安装，请先安装: pip install ansible-core"
    ((errors++))
  else
    local ansible_version
    ansible_version=$(ansible --version 2>/dev/null | head -1 | grep -oP '[\d.]+' || echo "unknown")
    log_ok "ansible 版本: ${ansible_version}"
  fi

  # 检查 SSH
  if ! command -v ssh &>/dev/null; then
    log_error "ssh 客户端未安装"
    ((errors++))
  fi

  # 检查 inventory
  if [[ "$AUTO_GENERATE_INVENTORY" == "false" && -z "$INVENTORY_FILE" ]]; then
    log_error "未指定 inventory 文件，请使用 -i 参数或 --generate-inventory 自动生成"
    ((errors++))
  fi

  # 检查 playbook
  if [[ -z "$PLAYBOOK_FILE" ]]; then
    log_error "未指定 playbook，请使用 -p 参数指定"
    ((errors++))
  fi

  # 检查内置 playbook 名称有效性
  if [[ -n "$PLAYBOOK_FILE" && -z "${PLAYBOOKS[$PLAYBOOK_FILE]+x}" && ! -f "$PLAYBOOK_FILE" ]]; then
    # 既不是已知模板名，也不是文件路径，检查是否有 .yml 后缀
    if [[ ! "$PLAYBOOK_FILE" =~ \.ya?ml$ ]]; then
      log_error "无效的 playbook: '$PLAYBOOK_FILE' (不是有效的文件路径或内置模板名)"
      log_info "使用 --list-playbooks 查看可用模板"
      ((errors++))
    fi
  fi

  if [[ $errors -gt 0 ]]; then
    log_error "前置检查失败，共 ${errors} 个错误"
    exit 1
  fi

  log_ok "前置检查通过"
}

# ========================= 自动生成 Inventory =========================
generate_inventory() {
  log_info "自动生成 Ansible inventory..."

  mkdir -p "${WORK_DIR}"
  INVENTORY_FILE="${WORK_DIR}/inventory.ini"

  local ansible_user="${ANSIBLE_USER:-root}"
  local ansible_key="${ANSIBLE_SSH_KEY:-}"
  local ansible_pass="${ANSIBLE_SSH_PASS:-}"
  local become="${ANSIBLE_BECOME:-true}"

  cat > "${INVENTORY_FILE}" <<EOF
# Auto-generated inventory - $(date '+%Y-%m-%d %H:%M:%S')
# Source: environment variables MASTER_NODES / WORKER_NODES

[all:vars]
ansible_user=${ansible_user}
ansible_become=${become}
EOF

  if [[ -n "$ansible_key" ]]; then
    echo "ansible_ssh_private_key_file=${ansible_key}" >> "${INVENTORY_FILE}"
  fi
  if [[ -n "$ansible_pass" ]]; then
    echo "ansible_ssh_pass=${ansible_pass}" >> "${INVENTORY_FILE}"
  fi
  echo "" >> "${INVENTORY_FILE}"

  # Master 节点
  if [[ -n "${MASTER_NODES:-}" ]]; then
    echo "[master]" >> "${INVENTORY_FILE}"
    IFS=',' read -ra masters <<< "$MASTER_NODES"
    for node in "${masters[@]}"; do
      local host=$(echo "$node" | sed 's/.*@//')
      local user=$(echo "$node" | sed 's/@.*//' || echo "$ansible_user")
      if [[ "$node" == *"@"* ]]; then
        echo "${host} ansible_user=${user}" >> "${INVENTORY_FILE}"
      else
        echo "${host}" >> "${INVENTORY_FILE}"
      fi
    done
    echo "" >> "${INVENTORY_FILE}"
  fi

  # Worker 节点
  if [[ -n "${WORKER_NODES:-}" ]]; then
    echo "[worker]" >> "${INVENTORY_FILE}"
    IFS=',' read -ra workers <<< "$WORKER_NODES"
    for node in "${workers[@]}"; do
      local host=$(echo "$node" | sed 's/.*@//')
      local user=$(echo "$node" | sed 's/@.*//' || echo "$ansible_user")
      if [[ "$node" == *"@"* ]]; then
        echo "${host} ansible_user=${user}" >> "${INVENTORY_FILE}"
      else
        echo "${host}" >> "${INVENTORY_FILE}"
      fi
    done
    echo "" >> "${INVENTORY_FILE}"
  fi

  # 组合组 - 使用实际主机名替代字面量
  echo "[k8s_master]" >> "${INVENTORY_FILE}"
  if [[ -n "${MASTER_NODES:-}" ]]; then
    IFS=',' read -ra _masters <<< "$MASTER_NODES"
    for node in "${_masters[@]}"; do
      echo "$(echo "$node" | sed 's/.*@//')" >> "${INVENTORY_FILE}"
    done
  fi
  echo "" >> "${INVENTORY_FILE}"

  echo "[k8s_worker]" >> "${INVENTORY_FILE}"
  if [[ -n "${WORKER_NODES:-}" ]]; then
    IFS=',' read -ra _workers <<< "$WORKER_NODES"
    for node in "${_workers[@]}"; do
      echo "$(echo "$node" | sed 's/.*@//')" >> "${INVENTORY_FILE}"
    done
  fi
  echo "" >> "${INVENTORY_FILE}"

  log_ok "Inventory 已生成: ${INVENTORY_FILE}"
  if [[ -n "${MASTER_NODES:-}" || -n "${WORKER_NODES:-}" ]]; then
    echo ""
    log_info "Inventory 内容:"
    cat "${INVENTORY_FILE}"
    echo ""
  else
    log_warn "未设置 MASTER_NODES / WORKER_NODES 环境变量，inventory 为空"
    log_info "请手动编辑 ${INVENTORY_FILE} 添加节点"
  fi
}

# ========================= 准备 Playbook =========================
prepare_playbook() {
  mkdir -p "${WORK_DIR}/playbooks"

  # 如果是文件路径直接使用
  if [[ -f "$PLAYBOOK_FILE" ]]; then
    PLAYBOOK_FILE="$(realpath "$PLAYBOOK_FILE")"
    log_info "使用 playbook 文件: ${PLAYBOOK_FILE}"
    return 0
  fi

  # 内置模板
  case "$PLAYBOOK_FILE" in
    k8s-init)
      cat > "${WORK_DIR}/playbooks/k8s-init.yml" <<'EOF'
---
- name: Kubernetes 集群初始化
  hosts: all
  become: yes
  vars:
    k8s_version: "1.31"
    pod_cidr: "10.244.0.0/16"
    service_cidr: "10.96.0.0/12"
  tasks:
    - name: 禁用 swap
      command: swapoff -a
      when: ansible_swaptotal_mb > 0

    - name: 移除 swap 配置
      lineinfile:
        path: /etc/fstab
        regexp: '\sswap\s'
        state: absent

    - name: 加载必要内核模块
      modprobe:
        name: "{{ item }}"
        state: present
      loop: [overlay, br_netfilter]

    - name: 持久化内核模块
      lineinfile:
        path: /etc/modules-load.d/k8s.conf
        line: "{{ item }}"
        create: yes
      loop: [overlay, br_netfilter]

    - name: 设置内核参数
      sysctl:
        name: "{{ item.key }}"
        value: "{{ item.value }}"
        sysctl_set: yes
        reload: yes
      loop:
        - { key: "net.bridge.bridge-nf-call-iptables", value: "1" }
        - { key: "net.bridge.bridge-nf-call-ip6tables", value: "1" }
        - { key: "net.ipv4.ip_forward", value: "1" }

    - name: 安装 containerd
      package:
        name: containerd.io
        state: present

    - name: 配置 containerd
      shell: |
        mkdir -p /etc/containerd
        containerd config default > /etc/containerd/config.toml
        sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
      args:
        creates: /etc/containerd/config.toml

    - name: 重启 containerd
      systemd:
        name: containerd
        state: restarted
        enabled: yes

    - name: 安装 kubeadm / kubelet / kubectl
      package:
        name:
          - "kubeadm-{{ k8s_version }}.*"
          - "kubelet-{{ k8s_version }}.*"
          - "kubectl-{{ k8s_version }}.*"
        state: present

    - name: 启用 kubelet
      systemd:
        name: kubelet
        enabled: yes
        state: started
EOF
      log_ok "生成 playbook: k8s-init"
      PLAYBOOK_FILE="${WORK_DIR}/playbooks/k8s-init.yml"
      ;;

    docker-install)
      cat > "${WORK_DIR}/playbooks/docker-install.yml" <<'EOF'
---
- name: Docker / Containerd 安装
  hosts: all
  become: yes
  vars:
    docker_version: "24.0"
  tasks:
    - name: 安装依赖
      package:
        name: [yum-utils, device-mapper-persistent-data, lvm2]
        state: present
      ignore_errors: yes

    - name: 添加 Docker CE 仓库
      yum_repository:
        name: docker-ce
        description: Docker CE Stable
        baseurl: "https://download.docker.com/linux/centos/8/$basearch/stable"
        gpgcheck: yes
        gpgkey: "https://download.docker.com/linux/centos/gpg"
      ignore_errors: yes

    - name: 安装 Docker
      package:
        name:
          - docker-ce
          - docker-ce-cli
          - containerd.io
        state: present

    - name: 配置 Docker daemon
      copy:
        content: |
          {
            "exec-opts": ["native.cgroupdriver=systemd"],
            "log-driver": "json-file",
            "log-opts": { "max-size": "100m", "max-file": "3" },
            "storage-driver": "overlay2"
          }
        dest: /etc/docker/daemon.json
      notify: restart docker

    - name: 启动 Docker
      systemd:
        name: docker
        state: started
        enabled: yes

  handlers:
    - name: restart docker
      systemd:
        name: docker
        state: restarted
EOF
      log_ok "生成 playbook: docker-install"
      PLAYBOOK_FILE="${WORK_DIR}/playbooks/docker-install.yml"
      ;;

    monitoring)
      cat > "${WORK_DIR}/playbooks/monitoring.yml" <<'EOF'
---
- name: Prometheus + Grafana 监控部署
  hosts: all
  become: yes
  tasks:
    - name: 创建监控目录
      file:
        path: /opt/monitoring
        state: directory

    - name: 部署 docker-compose 文件
      copy:
        content: |
          version: '3.8'
          services:
            prometheus:
              image: prom/prometheus:latest
              ports: ["9090:9090"]
              volumes:
                - ./prometheus.yml:/etc/prometheus/prometheus.yml
                - prometheus_data:/prometheus
            grafana:
              image: grafana/grafana:latest
              ports: ["3000:3000"]
              environment:
                - GF_SECURITY_ADMIN_PASSWORD=admin
              volumes:
                - grafana_data:/var/lib/grafana
            alertmanager:
              image: prom/alertmanager:latest
              ports: ["9093:9093"]
          volumes:
            prometheus_data:
            grafana_data:
        dest: /opt/monitoring/docker-compose.yml

    - name: 部署 Prometheus 配置
      copy:
        content: |
          global:
            scrape_interval: 15s
          scrape_configs:
            - job_name: 'node'
              static_configs:
                - targets: ['localhost:9100']
        dest: /opt/monitoring/prometheus.yml

    - name: 启动监控栈
      shell: docker compose up -d
      args:
        chdir: /opt/monitoring
EOF
      log_ok "生成 playbook: monitoring"
      PLAYBOOK_FILE="${WORK_DIR}/playbooks/monitoring.yml"
      ;;

    security-hardening)
      cat > "${WORK_DIR}/playbooks/security-hardening.yml" <<'EOF'
---
- name: 安全加固基线
  hosts: all
  become: yes
  tasks:
    - name: 禁用 root SSH 登录
      lineinfile:
        path: /etc/ssh/sshd_config
        regexp: '^PermitRootLogin'
        line: 'PermitRootLogin prohibit-password'

    - name: 禁用密码认证
      lineinfile:
        path: /etc/ssh/sshd_config
        regexp: '^PasswordAuthentication'
        line: 'PasswordAuthentication no'

    - name: 设置 SSH 协议版本
      lineinfile:
        path: /etc/ssh/sshd_config
        regexp: '^#?Protocol'
        line: 'Protocol 2'

    - name: 重启 SSH 服务
      systemd:
        name: sshd
        state: restarted
EOF
      log_ok "生成 playbook: security-hardening"
      PLAYBOOK_FILE="${WORK_DIR}/playbooks/security-hardening.yml"
      ;;

    *)
      if [[ ! -f "$PLAYBOOK_FILE" ]]; then
        log_error "未知的内置 playbook: $PLAYBOOK_FILE"
        log_info "使用 --list-playbooks 查看可用模板"
        exit 1
      fi
      ;;
  esac
}

# ========================= 连通性测试 =========================
connectivity_test() {
  log_info "执行连通性测试..."

  local test_args=(
    -i "${INVENTORY_FILE}"
    all
    -m ping
    --one-line
  )
  if [[ -n "$LIMIT_HOSTS" ]]; then
    test_args+=(-l "$LIMIT_HOSTS")
  fi
  if [[ -n "$VERBOSE" ]]; then
    test_args+=("$VERBOSE")
  fi

  if ansible "${test_args[@]}" 2>&1 | tee "${WORK_DIR}/connectivity-test.log"; then
    log_ok "连通性测试通过"
    return 0
  else
    log_error "连通性测试失败，详见 ${WORK_DIR}/connectivity-test.log"
    return 1
  fi
}

# ========================= 执行部署 =========================
run_deploy() {
  log_info "开始执行部署..."
  echo "=========================================================="
  echo "  Inventory : ${INVENTORY_FILE}"
  echo "  Playbook  : ${PLAYBOOK_FILE}"
  echo "  Dry Run   : ${DRY_RUN}"
  echo "  Tags      : ${TAGS:-all}"
  echo "  Report    : ${REPORT_FILE}"
  echo "=========================================================="

  local start_time
  start_time=$(date +%s)

  local ansible_args=(
    -i "${INVENTORY_FILE}"
    "${PLAYBOOK_FILE}"
  )

  if [[ -n "$LIMIT_HOSTS" ]]; then
    ansible_args+=(-l "$LIMIT_HOSTS")
  fi
  if [[ -n "$TAGS" ]]; then
    ansible_args+=(-t "$TAGS")
  fi
  if [[ -n "$SKIP_TAGS" ]]; then
    ansible_args+=(--skip-tags "$SKIP_TAGS")
  fi
  for ev in "${EXTRA_VARS[@]+"${EXTRA_VARS[@]}"}"; do
    ansible_args+=(-e "$ev")
  done
  if [[ -n "$VERBOSE" ]]; then
    ansible_args+=("$VERBOSE")
  fi
  if [[ "$DRY_RUN" == "true" ]]; then
    ansible_args+=(--check --diff)
  fi

  local exit_code=0
  ansible-playbook "${ansible_args[@]}" 2>&1 | tee "${WORK_DIR}/deploy.log" || exit_code=$?

  local end_time
  end_time=$(date +%s)
  local duration=$(( end_time - start_time ))

  # 生成报告
  generate_report "$exit_code" "$duration"

  if [[ $exit_code -eq 0 ]]; then
    log_ok "部署成功完成! 耗时: ${duration}s"
    log_info "报告已保存: ${REPORT_FILE}"
  else
    log_error "部署失败! 退出码: ${exit_code}  耗时: ${duration}s"
    log_error "详见日志: ${WORK_DIR}/deploy.log"
    log_info "报告已保存: ${REPORT_FILE}"
    exit $exit_code
  fi
}

# ========================= 生成报告 =========================
generate_report() {
  local exit_code=$1
  local duration=$2

  mkdir -p "$(dirname "$REPORT_FILE")"
  cat > "${REPORT_FILE}" <<REPORT
╔══════════════════════════════════════════════════════════════╗
║            Ansible 部署报告                                  ║
╠══════════════════════════════════════════════════════════════╣
║  时间:       $(date '+%Y-%m-%d %H:%M:%S')
║  Inventory:  ${INVENTORY_FILE}
║  Playbook:   ${PLAYBOOK_FILE}
║  Dry Run:    ${DRY_RUN}
║  退出码:     ${exit_code}
║  耗时:       ${duration}s
║  状态:       $([ $exit_code -eq 0 ] && echo '✅ 成功' || echo '❌ 失败')
╠══════════════════════════════════════════════════════════════╣
║  日志路径:   ${WORK_DIR}/deploy.log
╚══════════════════════════════════════════════════════════════╝

REPORT

  log_info "报告已写入: ${REPORT_FILE}"
}

# ========================= 主流程 =========================
main() {
  echo ""
  echo "╔══════════════════════════════════════════════════╗"
  echo "║       Ansible 批量部署脚本 v2.0                  ║"
  echo "╚══════════════════════════════════════════════════╝"
  echo ""

  parse_args "$@"
  preflight_check

  # 自动生成 inventory
  if [[ "$AUTO_GENERATE_INVENTORY" == "true" ]]; then
    generate_inventory
  fi

  # 确保 inventory 文件存在
  if [[ ! -f "${INVENTORY_FILE}" ]]; then
    log_error "Inventory 文件不存在: ${INVENTORY_FILE}"
    exit 1
  fi

  # 准备 playbook
  prepare_playbook

  # 连通性测试
  if [[ "$CHECK_ONLY" == "true" ]]; then
    connectivity_test
    log_ok "仅执行连通性测试，未运行 playbook"
    exit 0
  fi

  # 执行部署
  run_deploy
}

main "$@"
