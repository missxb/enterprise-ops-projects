# 企业级项目05: Ansible 自动化运维平台

## 📋 项目概述

完整的企业级Ansible自动化运维方案，包含服务器初始化、应用部署、配置管理、安全加固。

**适用场景**: 批量服务器管理、标准化配置、自动化巡检、安全合规

---

## 🏗️ 架构图

```
┌─────────────────────────────────────────────────────────────────┐
│                    Ansible 自动化运维架构                         │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │                    控制节点 (Ansible Tower/AWX)          │   │
│  │                                                          │   │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐     │   │
│  │  │   Playbooks │  │   Roles     │  │   Inventory │     │   │
│  │  │   (剧本)    │  │   (角色)    │  │   (清单)    │     │   │
│  │  └─────────────┘  └─────────────┘  └─────────────┘     │   │
│  │                                                          │   │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐     │   │
│  │  │   Vault     │  │   Facts     │  │   Templates │     │   │
│  │  │  (加密)     │  │  (变量)     │  │  (模板)     │     │   │
│  │  └─────────────┘  └─────────────┘  └─────────────┘     │   │
│  └──────────────────────────┬───────────────────────────────┘   │
│                              │ SSH                              │
│  ════════════════════════════╪══════════════════════════════     │
│                              │                                  │
│  ┌──────────────────────────▼───────────────────────────────┐   │
│  │                    受管节点                                │   │
│  │                                                          │   │
│  │  ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐       │   │
│  │  │ Web-01  │ │ Web-02  │ │ DB-01   │ │ Redis-01│       │   │
│  │  │ Nginx   │ │ Nginx   │ │ MySQL   │ │ Redis   │       │   │
│  │  │ +App    │ │ +App    │ │ Primary │ │ Primary │       │   │
│  │  └─────────┘ └─────────┘ └─────────┘ └─────────┘       │   │
│  │                                                          │   │
│  │  ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐       │   │
│  │  │ DB-02   │ │ Redis-02│ │ Monitor │ │ Jenkins │       │   │
│  │  │ MySQL   │ │ Redis   │ │Prometheus│ │ CI/CD   │       │   │
│  │  │ Replica │ │ Replica │ │ Grafana │ │         │       │   │
│  │  └─────────┘ └─────────┘ └─────────┘ └─────────┘       │   │
│  └─────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

---

## 📁 项目文件结构

```
ansible-automation/
├── ansible.cfg                     # Ansible配置
├── inventory/
│   ├── production/
│   │   ├── hosts                   # 生产环境主机清单
│   │   └── group_vars/
│   │       ├── all.yml             # 全局变量
│   │       ├── webservers.yml      # Web服务器变量
│   │       ├── dbservers.yml       # 数据库服务器变量
│   │       └── vault.yml           # 加密变量
│   └── staging/
│       ├── hosts                   # 测试环境主机清单
│       └── group_vars/
├── playbooks/
│   ├── 01-init-servers.yml         # 服务器初始化
│   ├── 02-install-docker.yml       # 安装Docker
│   ├── 03-deploy-app.yml           # 部署应用
│   ├── 04-setup-monitoring.yml     # 部署监控
│   ├── 05-security-hardening.yml   # 安全加固
│   ├── 06-backup.yml               # 备份任务
│   └── 07-rolling-update.yml       # 滚动更新
├── roles/
│   ├── common/                     # 通用配置
│   │   ├── tasks/main.yml
│   │   ├── handlers/main.yml
│   │   ├── templates/
│   │   ├── files/
│   │   └── defaults/main.yml
│   ├── docker/                     # Docker安装
│   ├── nginx/                      # Nginx配置
│   ├── mysql/                      # MySQL配置
│   ├── redis/                      # Redis配置
│   ├── monitoring/                 # 监控配置
│   └── security/                   # 安全加固
├── templates/
│   ├── nginx.conf.j2
│   ├── mysql.cnf.j2
│   └── redis.conf.j2
├── group_vars/
│   └── all.yml                     # 全局变量
├── host_vars/
│   └── web-01.yml                  # 主机特定变量
├── scripts/
│   ├── run-pipeline.sh             # 一键执行流水线
│   ├── health-check.sh             # 健康检查
│   └── rollback.sh                 # 回滚脚本
└── README.md
```

---

## 🚀 部署方案

### ansible.cfg

```ini
[defaults]
inventory = ./inventory/production/hosts
remote_user = deploy
private_key_file = ~/.ssh/id_ed25519
host_key_checking = False
retry_files_enabled = False
stdout_callback = yaml
callback_whitelist = timer, profile_tasks
forks = 20
timeout = 30
gathering = smart
fact_caching = jsonfile
fact_caching_connection = /tmp/ansible_facts_cache
fact_caching_timeout = 3600

[privilege_escalation]
become = True
become_method = sudo
become_user = root
become_ask_pass = False

[ssh_connection]
ssh_args = -C -o ControlMaster=auto -o ControlPersist=60s -o ServerAliveInterval=30
pipelining = True
control_path = /tmp/ansible-%%r@%%h:%%p
```

### inventory/production/hosts

```ini
# ============================================
# 生产环境主机清单
# ============================================

[webservers]
web-01 ansible_host=192.168.1.21
web-02 ansible_host=192.168.1.22
web-03 ansible_host=192.168.1.23

[dbservers]
db-01 ansible_host=192.168.1.31 mysql_role=master
db-02 ansible_host=192.168.1.32 mysql_role=slave
db-03 ansible_host=192.168.1.33 mysql_role=slave

[redis_servers]
redis-01 ansible_host=192.168.1.41 redis_role=master
redis-02 ansible_host=192.168.1.42 redis_role=slave

[monitoring]
monitor-01 ansible_host=192.168.1.51

[jenkins]
jenkins-01 ansible_host=192.168.1.61

[all:vars]
ansible_python_interpreter=/usr/bin/python3
ansible_ssh_common_args='-o StrictHostKeyChecking=no'
```

### group_vars/all.yml

```yaml
# ============================================
# 全局变量
# ============================================

# 基础配置
domain_name: "company.com"
timezone: "Asia/Shanghai"
ntp_servers:
  - "ntp.aliyun.com"
  - "ntp.tencent.com"

# 用户配置
deploy_user: "deploy"
deploy_group: "deploy"
deploy_user_shell: "/bin/bash"

# SSH配置
ssh_port: 22
ssh_permit_root_login: "prohibit-password"
ssh_password_authentication: "no"
ssh_pubkey_file: "files/authorized_keys"

# 防火墙配置
firewall_allowed_ports:
  - 22
  - 80
  - 443
  - 9090
  - 3000
  - 8080

# Docker配置
docker_edition: "ce"
docker_compose_version: "2.23.0"
docker_mirror: "https://mirror.ccs.tencentyun.com"

# Nginx配置
nginx_worker_processes: "auto"
nginx_worker_connections: 65535
nginx_keepalive_timeout: 65

# MySQL配置
mysql_root_password: "{{ vault_mysql_root_password }}"
mysql_app_password: "{{ vault_mysql_app_password }}"
mysql_database: "enterprise_app"
mysql_max_connections: 500
mysql_innodb_buffer_pool_size: "4G"

# Redis配置
redis_password: "{{ vault_redis_password }}"
redis_max_memory: "2gb"
redis_max_memory_policy: "allkeys-lru"

# 监控配置
prometheus_retention: "30d"
grafana_admin_password: "{{ vault_grafana_admin_password }}"

# 备份配置
backup_retention_days: 30
backup_path: "/data/backups"
backup_s3_bucket: "s3://company-backups"

# 邮件配置
smtp_server: "smtp.company.com"
smtp_port: 587
smtp_user: "alerts@company.com"
smtp_password: "{{ vault_smtp_password }}"
alert_email: "ops-team@company.com"
```

### group_vars/webservers.yml

```yaml
# ============================================
# Web服务器变量
# ============================================

# Nginx配置
nginx_worker_rlimit_nofile: 65535
nginx_client_max_body_size: "50m"
nginx_proxy_connect_timeout: 60
nginx_proxy_send_timeout: 60
nginx_proxy_read_timeout: 60
nginx_gzip_enabled: true
nginx_ssl_enabled: true
nginx_ssl_certificate: "/etc/nginx/ssl/fullchain.pem"
nginx_ssl_certificate_key: "/etc/nginx/ssl/privkey.pem"

# 应用配置
app_name: "enterprise-app"
app_port: 8000
app_workers: 4
app_log_level: "info"
app_env: "production"

# 限流配置
rate_limit_zone_size: "10m"
rate_limit_rate: "10r/s"
rate_limit_burst: 20
```

### group_vars/dbservers.yml

```yaml
# ============================================
# 数据库服务器变量
# ============================================

mysql_version: "8.0"
mysql_datadir: "/var/lib/mysql"
mysql_logdir: "/var/log/mysql"
mysql_backup_dir: "/data/backups/mysql"

# InnoDB配置
mysql_innodb_buffer_pool_size: "4G"
mysql_innodb_log_file_size: "256M"
mysql_innodb_flush_log_at_trx_commit: 2
mysql_innodb_flush_method: "O_DIRECT"

# 连接配置
mysql_max_connections: 500
mysql_wait_timeout: 600
mysql_interactive_timeout: 600

# 慢查询
mysql_slow_query_log: true
mysql_long_query_time: 2

# 复制配置（从库）
mysql_server_id: "{{ groups['dbservers'].index(inventory_hostname) + 1 }}"
mysql_binlog_format: "ROW"
mysql_gtid_mode: "ON"
```

---

## 📋 Playbooks

### playbooks/01-init-servers.yml

```yaml
# ============================================
# 服务器初始化 Playbook
# ============================================
---
- name: 服务器初始化
  hosts: all
  become: yes
  gather_facts: yes
  
  vars:
    required_packages:
      - curl
      - wget
      - vim
      - htop
      - net-tools
      - lsof
      - tree
      - jq
      - unzip
      - git
      - tmux
      - iotop
      - sysstat
  
  tasks:
    # ===== 主机名 =====
    - name: 设置主机名
      hostname:
        name: "{{ inventory_hostname }}.{{ domain_name }}"
    
    # ===== 时区 =====
    - name: 设置时区
      timezone:
        name: "{{ timezone }}"
    
    # ===== NTP时间同步 =====
    - name: 安装chrony
      package:
        name: chrony
        state: present
    
    - name: 配置chrony
      template:
        src: chrony.conf.j2
        dest: /etc/chrony/chrony.conf
      notify: restart chrony
    
    - name: 启动chrony
      service:
        name: chronyd
        state: started
        enabled: yes
    
    # ===== 系统参数优化 =====
    - name: 配置系统参数
      sysctl:
        name: "{{ item.key }}"
        value: "{{ item.value }}"
        sysctl_file: /etc/sysctl.d/99-kubernetes.conf
        reload: yes
      loop:
        - { key: "net.ipv4.ip_forward", value: "1" }
        - { key: "net.bridge.bridge-nf-call-iptables", value: "1" }
        - { key: "net.ipv4.tcp_keepalive_time", value: "600" }
        - { key: "net.ipv4.tcp_keepalive_intvl", value: "30" }
        - { key: "net.ipv4.tcp_keepalive_probes", value: "5" }
        - { key: "fs.inotify.max_user_watches", value: "524288" }
        - { key: "fs.inotify.max_user_instances", value: "512" }
        - { key: "vm.swappiness", value: "10" }
        - { key: "net.core.somaxconn", value: "65535" }
        - { key: "net.ipv4.tcp_max_syn_backlog", value: "65535" }
    
    # ===== 文件描述符限制 =====
    - name: 配置文件描述符限制
      pam_limits:
        domain: "*"
        limit_type: "{{ item.type }}"
        limit_item: "{{ item.item }}"
        value: "{{ item.value }}"
      loop:
        - { type: "soft", item: "nofile", value: "65535" }
        - { type: "hard", item: "nofile", value: "65535" }
        - { type: "soft", item: "nproc", value: "65535" }
        - { type: "hard", item: "nproc", value: "65535" }
    
    # ===== 禁用Swap =====
    - name: 禁用Swap
      command: swapoff -a
      when: ansible_swaptotal_mb > 0
    
    - name: 永久禁用Swap
      lineinfile:
        path: /etc/fstab
        regexp: '.*swap.*'
        state: absent
    
    # ===== 安装必要软件 =====
    - name: 更新apt缓存
      apt:
        update_cache: yes
        cache_valid_time: 3600
      when: ansible_os_family == "Debian"
    
    - name: 安装必要软件
      package:
        name: "{{ required_packages }}"
        state: present
    
    # ===== 创建部署用户 =====
    - name: 创建部署用户组
      group:
        name: "{{ deploy_group }}"
        state: present
    
    - name: 创建部署用户
      user:
        name: "{{ deploy_user }}"
        group: "{{ deploy_group }}"
        shell: "{{ deploy_user_shell }}"
        create_home: yes
        state: present
    
    - name: 配置sudo权限
      lineinfile:
        path: /etc/sudoers.d/{{ deploy_user }}
        line: "{{ deploy_user }} ALL=(ALL) NOPASSWD:ALL"
        create: yes
        mode: '0440'
        validate: 'visudo -cf %s'
    
    # ===== SSH安全加固 =====
    - name: 配置SSH
      lineinfile:
        path: /etc/ssh/sshd_config
        regexp: "{{ item.regexp }}"
        line: "{{ item.line }}"
      loop:
        - { regexp: '^#?Port ', line: "Port {{ ssh_port }}" }
        - { regexp: '^#?PermitRootLogin', line: "PermitRootLogin {{ ssh_permit_root_login }}" }
        - { regexp: '^#?PasswordAuthentication', line: "PasswordAuthentication {{ ssh_password_authentication }}" }
        - { regexp: '^#?MaxAuthTries', line: "MaxAuthTries 3" }
        - { regexp: '^#?ClientAliveInterval', line: "ClientAliveInterval 300" }
        - { regexp: '^#?ClientAliveCountMax', line: "ClientAliveCountMax 2" }
      notify: restart sshd
    
    # ===== 配置防火墙 =====
    - name: 安装UFW
      package:
        name: ufw
        state: present
      when: ansible_os_family == "Debian"
    
    - name: 配置UFW默认策略
      ufw:
        direction: "{{ item.direction }}"
        policy: "{{ item.policy }}"
      loop:
        - { direction: incoming, policy: deny }
        - { direction: outgoing, policy: allow }
    
    - name: 允许SSH端口
      ufw:
        rule: allow
        port: "{{ ssh_port }}"
        proto: tcp
    
    - name: 允许其他端口
      ufw:
        rule: allow
        port: "{{ item }}"
        proto: tcp
      loop: "{{ firewall_allowed_ports }}"
    
    - name: 启用UFW
      ufw:
        state: enabled
    
    # ===== 配置日志轮转 =====
    - name: 配置日志轮转
      template:
        src: logrotate.conf.j2
        dest: /etc/logrotate.d/app
        owner: root
        group: root
        mode: '0644'
  
  handlers:
    - name: restart chrony
      service:
        name: chronyd
        state: restarted
    
    - name: restart sshd
      service:
        name: sshd
        state: restarted
```

### playbooks/02-install-docker.yml

```yaml
# ============================================
# Docker安装 Playbook
# ============================================
---
- name: 安装Docker
  hosts: webservers:dbservers:monitoring:jenkins
  become: yes
  gather_facts: yes
  
  tasks:
    # ===== 卸载旧版本 =====
    - name: 卸载旧版本Docker
      apt:
        name:
          - docker
          - docker-engine
          - docker.io
          - containerd
          - runc
        state: absent
    
    # ===== 安装依赖 =====
    - name: 安装Docker依赖
      apt:
        name:
          - apt-transport-https
          - ca-certificates
          - curl
          - gnupg
          - lsb-release
        state: present
    
    # ===== 添加Docker GPG密钥 =====
    - name: 添加Docker GPG密钥
      apt_key:
        url: https://download.docker.com/linux/ubuntu/gpg
        state: present
    
    # ===== 添加Docker仓库 =====
    - name: 添加Docker仓库
      apt_repository:
        repo: "deb [arch={{ ansible_architecture }}] https://download.docker.com/linux/ubuntu {{ ansible_distribution_release }} stable"
        state: present
    
    # ===== 安装Docker =====
    - name: 安装Docker CE
      apt:
        name:
          - docker-ce
          - docker-ce-cli
          - containerd.io
          - docker-buildx-plugin
          - docker-compose-plugin
        state: present
        update_cache: yes
    
    # ===== 配置Docker =====
    - name: 创建Docker配置目录
      file:
        path: /etc/docker
        state: directory
        mode: '0755'
    
    - name: 配置Docker Daemon
      template:
        src: daemon.json.j2
        dest: /etc/docker/daemon.json
      notify: restart docker
    
    # ===== 启动Docker =====
    - name: 启动Docker
      service:
        name: docker
        state: started
        enabled: yes
    
    # ===== 配置用户组 =====
    - name: 将部署用户添加到docker组
      user:
        name: "{{ deploy_user }}"
        groups: docker
        append: yes
    
    # ===== 安装Docker Compose =====
    - name: 检查Docker Compose版本
      command: docker compose version
      register: docker_compose_check
      ignore_errors: yes
    
    - name: 安装Docker Compose
      get_url:
        url: "https://github.com/docker/compose/releases/download/v{{ docker_compose_version }}/docker-compose-linux-{{ ansible_architecture }}"
        dest: /usr/local/bin/docker-compose
        mode: '0755'
      when: docker_compose_check.rc != 0
    
    # ===== 配置日志轮转 =====
    - name: 配置Docker日志轮转
      copy:
        content: |
          {
            "log-driver": "json-file",
            "log-opts": {
              "max-size": "50m",
              "max-file": "5"
            }
          }
        dest: /etc/docker/daemon.json
      notify: restart docker
  
  handlers:
    - name: restart docker
      service:
        name: docker
        state: restarted
```

### playbooks/03-deploy-app.yml

```yaml
# ============================================
# 应用部署 Playbook
# ============================================
---
- name: 部署企业应用
  hosts: webservers
  become: yes
  serial: "30%"  # 滚动更新，每次30%
  
  vars:
    app_image: "registry:5000/enterprise-app"
    app_version: "latest"
    app_container_name: "enterprise-app"
    app_port: 8000
    health_check_url: "http://localhost:{{ app_port }}/health"
    health_check_retries: 30
    health_check_delay: 10
  
  tasks:
    # ===== 创建应用目录 =====
    - name: 创建应用目录
      file:
        path: "/opt/{{ app_name }}"
        state: directory
        owner: "{{ deploy_user }}"
        group: "{{ deploy_group }}"
        mode: '0755'
      loop:
        - /opt/{{ app_name }}
        - /opt/{{ app_name }}/config
        - /opt/{{ app_name }}/logs
        - /opt/{{ app_name }}/uploads
    
    # ===== 复制配置文件 =====
    - name: 复制应用配置
      template:
        src: "templates/app-config.yml.j2"
        dest: "/opt/{{ app_name }}/config/app.yml"
        owner: "{{ deploy_user }}"
        group: "{{ deploy_group }}"
    
    - name: 复制环境变量
      template:
        src: "templates/app.env.j2"
        dest: "/opt/{{ app_name }}/config/app.env"
        owner: "{{ deploy_user }}"
        group: "{{ deploy_group }}"
        mode: '0600'
    
    # ===== 停止旧版本 =====
    - name: 停止旧版本应用
      docker_container:
        name: "{{ app_container_name }}"
        state: absent
      ignore_errors: yes
    
    # ===== 拉取新镜像 =====
    - name: 拉取应用镜像
      docker_image:
        name: "{{ app_image }}:{{ app_version }}"
        source: pull
        force_source: yes
    
    # ===== 启动新版本 =====
    - name: 启动应用容器
      docker_container:
        name: "{{ app_container_name }}"
        image: "{{ app_image }}:{{ app_version }}"
        state: started
        restart_policy: unless-stopped
        ports:
          - "{{ app_port }}:{{ app_port }}"
        env_file:
          - "/opt/{{ app_name }}/config/app.env"
        volumes:
          - "/opt/{{ app_name }}/config:/app/config:ro"
          - "/opt/{{ app_name }}/logs:/app/logs"
          - "/opt/{{ app_name }}/uploads:/app/uploads"
        resources:
          limits:
            cpus: "2"
            memory: 1G
          reservations:
            cpus: "0.5"
            memory: 256M
        healthcheck:
          test: ["CMD", "curl", "-f", "{{ health_check_url }}"]
          interval: 30s
          timeout: 10s
          retries: 3
          start_period: 30s
        logging:
          driver: json-file
          options:
            max-size: "50m"
            max-file: "5"
        labels:
          app: "{{ app_name }}"
          version: "{{ app_version }}"
    
    # ===== 健康检查 =====
    - name: 等待应用就绪
      uri:
        url: "{{ health_check_url }}"
        status_code: 200
      register: health_check
      retries: "{{ health_check_retries }}"
      delay: "{{ health_check_delay }}"
      until: health_check.status == 200
    
    - name: 显示应用状态
      debug:
        msg: "✅ {{ inventory_hostname }} 应用部署成功! 版本: {{ app_version }}"
```

### playbooks/05-security-hardening.yml

```yaml
# ============================================
# 安全加固 Playbook
# ============================================
---
- name: 安全加固
  hosts: all
  become: yes
  
  tasks:
    # ===== 系统安全 =====
    - name: 安装安全软件
      package:
        name:
          - fail2ban
          - aide
          - auditd
          - libpam-pwquality
        state: present
    
    # ===== 配置fail2ban =====
    - name: 配置fail2ban
      template:
        src: jail.local.j2
        dest: /etc/fail2ban/jail.local
      notify: restart fail2ban
    
    - name: 启动fail2ban
      service:
        name: fail2ban
        state: started
        enabled: yes
    
    # ===== 内核安全参数 =====
    - name: 配置内核安全参数
      sysctl:
        name: "{{ item.key }}"
        value: "{{ item.value }}"
        sysctl_file: /etc/sysctl.d/99-security.conf
        reload: yes
      loop:
        - { key: "net.ipv4.conf.all.rp_filter", value: "1" }
        - { key: "net.ipv4.conf.default.rp_filter", value: "1" }
        - { key: "net.ipv4.icmp_echo_ignore_broadcasts", value: "1" }
        - { key: "net.ipv4.conf.all.accept_redirects", value: "0" }
        - { key: "net.ipv4.conf.default.accept_redirects", value: "0" }
        - { key: "net.ipv4.conf.all.send_redirects", value: "0" }
        - { key: "net.ipv4.conf.default.send_redirects", value: "0" }
        - { key: "net.ipv4.conf.all.accept_source_route", value: "0" }
        - { key: "net.ipv4.conf.default.accept_source_route", value: "0" }
        - { key: "net.ipv4.tcp_syncookies", value: "1" }
        - { key: "net.ipv4.tcp_max_tw_buckets", value: "1440000" }
        - { key: "net.ipv4.tcp_tw_reuse", value: "1" }
        - { key: "net.ipv4.tcp_fin_timeout", value: "15" }
        - { key: "kernel.randomize_va_space", value: "2" }
        - { key: "fs.suid_dumpable", value: "0" }
    
    # ===== 密码策略 =====
    - name: 配置密码策略
      lineinfile:
        path: /etc/security/pwquality.conf
        regexp: "{{ item.regexp }}"
        line: "{{ item.line }}"
      loop:
        - { regexp: '^# ?minlen', line: 'minlen = 12' }
        - { regexp: '^# ?dcredit', line: 'dcredit = -1' }
        - { regexp: '^# ?ucredit', line: 'ucredit = -1' }
        - { regexp: '^# ?lcredit', line: 'lcredit = -1' }
        - { regexp: '^# ?ocredit', line: 'ocredit = -1' }
    
    # ===== 禁用不必要的服务 =====
    - name: 禁用不必要的服务
      service:
        name: "{{ item }}"
        state: stopped
        enabled: no
      loop:
        - avahi-daemon
        - cups
        - bluetooth
        - rpcbind
      ignore_errors: yes
    
    # ===== 配置审计 =====
    - name: 配置审计规则
      copy:
        content: |
          -w /etc/passwd -p wa -k identity
          -w /etc/group -p wa -k identity
          -w /etc/shadow -p wa -k identity
          -w /etc/sudoers -p wa -k sudoers
          -w /var/log/auth.log -p wa -k auth
          -w /var/log/syslog -p wa -k syslog
        dest: /etc/audit/rules.d/custom.rules
      notify: restart auditd
    
    # ===== 配置AIDE入侵检测 =====
    - name: 初始化AIDE数据库
      command: aideinit
      creates: /var/lib/aide/aide.db.new
    
    - name: 移动AIDE数据库
      command: mv /var/lib/aide/aide.db.new /var/lib/aide/aide.db
      creates: /var/lib/aide/aide.db
    
    # ===== 定时安全检查 =====
    - name: 添加定时安全检查
      cron:
        name: "AIDE完整性检查"
        minute: "0"
        hour: "3"
        job: "/usr/bin/aide --check | mail -s 'AIDE Integrity Report' {{ alert_email }}"
```

---

## 🔧 运维手册

### 常用命令

```bash
# 测试连通性
ansible all -m ping -i inventory/production/hosts

# 执行命令
ansible webservers -m shell -a "uptime" -i inventory/production/hosts

# 运行Playbook
ansible-playbook playbooks/01-init-servers.yml -i inventory/production/hosts

# 运行特定任务
ansible-playbook playbooks/03-deploy-app.yml -i inventory/production/hosts --tags "deploy"

# 限制主机执行
ansible-playbook playbooks/03-deploy-app.yml -l "web-01"

# 检查模式（dry run）
ansible-playbook playbooks/03-deploy-app.yml --check --diff

# 调试模式
ansible-playbook playbooks/03-deploy-app.yml -vvv

# 查看变量
ansible web-01 -m debug -a "var=ansible_distribution"

# 执行备份
ansible-playbook playbooks/06-backup.yml -i inventory/production/hosts
```

### 加密敏感数据

```bash
# 加密变量文件
ansible-vault encrypt group_vars/production/vault.yml

# 编辑加密文件
ansible-vault edit group_vars/production/vault.yml

# 运行时输入密码
ansible-playbook playbooks/deploy.yml --ask-vault-pass

# 使用密码文件
ansible-playbook playbooks/deploy.yml --vault-password-file=.vault_pass
```

---

**作者**: 企业级运维项目集
**版本**: 1.0.0
**更新时间**: 2026-05-02
