# 企业级Ansible + Terraform自动化运维

> 完整实现自动化运维体系，覆盖配置管理、基础设施即代码、批量运维、CI/CD集成

---

## 一、架构

```
┌─────────────────────────────────────────────────┐
│                  运维控制中心                      │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐      │
│  │ Ansible  │  │ Terraform│  │ Jenkins  │      │
│  │ 配置管理  │  │ IaC      │  │ CI/CD    │      │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘      │
└───────┼──────────────┼──────────────┼────────────┘
        │              │              │
        ▼              ▼              ▼
   ┌─────────┐   ┌──────────┐  ┌──────────┐
   │ 服务器   │   │ 云资源    │  │ 容器集群  │
   │ 200+台  │   │ VPC/ECS  │  │ K8s      │
   └─────────┘   └──────────┘  └──────────┘
```

---

## 二、Ansible项目结构

```
ansible-ops/
├── ansible.cfg
├── inventory/
│   ├── production/
│   │   ├── hosts              # 主机清单
│   │   └── group_vars/
│   │       ├── all.yml        # 全局变量
│   │       ├── webservers.yml
│   │       ├── dbservers.yml
│   │       └── cacheservers.yml
│   └── staging/
├── playbooks/
│   ├── site.yml               # 主入口
│   ├── base.yml               # 基础配置
│   ├── docker.yml             # Docker部署
│   ├── k8s.yml                # K8s部署
│   ├── monitoring.yml         # 监控部署
│   ├── mysql.yml              # MySQL部署
│   └── security.yml           # 安全加固
├── roles/
│   ├── common/
│   ├── docker/
│   ├── k8s/
│   ├── nginx/
│   ├── mysql/
│   ├── redis/
│   ├── prometheus/
│   └── security/
├── collections/
│   └── requirements.yml
└── Makefile
```

### 2.1 主机清单

```ini
# inventory/production/hosts
[all:vars]
ansible_user=deploy
ansible_become=yes
ansible_python_interpreter=/usr/bin/python3
ansible_ssh_private_key_file=~/.ssh/deploy_key

[webservers]
web-01 ansible_host=10.10.10.21
web-02 ansible_host=10.10.10.22
web-03 ansible_host=10.10.10.23

[dbservers]
db-01 ansible_host=10.10.30.11
db-02 ansible_host=10.10.30.12
db-03 ansible_host=10.10.30.13

[cacheservers]
cache-01 ansible_host=10.10.40.11
cache-02 ansible_host=10.10.40.12
cache-03 ansible_host=10.10.40.13

[k8s:children]
k8s_masters
k8s_workers

[k8s_masters]
k8s-master-01 ansible_host=10.10.10.11
k8s-master-02 ansible_host=10.10.10.12
k8s-master-03 ansible_host=10.10.10.13

[k8s_workers]
k8s-worker-01 ansible_host=10.10.10.21
k8s-worker-02 ansible_host=10.10.10.22
k8s-worker-03 ansible_host=10.10.10.23
```

### 2.2 基础配置Playbook

```yaml
# playbooks/base.yml
---
- name: 基础服务器配置
  hosts: all
  become: yes
  vars:
    timezone: "Asia/Shanghai"
    ntp_servers:
      - ntp.aliyun.com
      - ntp1.aliyun.com
  
  tasks:
    - name: 设置时区
      timezone:
        name: "{{ timezone }}"
    
    - name: 配置NTP
      template:
        src: chrony.conf.j2
        dest: /etc/chrony.conf
      notify: restart chrony
    
    - name: 关闭SELinux
      selinux:
        state: disabled
    
    - name: 关闭防火墙
      systemd:
        name: firewalld
        state: stopped
        enabled: no
    
    - name: 加载内核模块
      modprobe:
        name: "{{ item }}"
        state: present
      loop:
        - overlay
        - br_netfilter
    
    - name: 配置内核参数
      sysctl:
        name: "{{ item.name }}"
        value: "{{ item.value }}"
        sysctl_set: yes
        reload: yes
      loop:
        - { name: 'net.bridge.bridge-nf-call-iptables', value: '1' }
        - { name: 'net.ipv4.ip_forward', value: '1' }
        - { name: 'vm.swappiness', value: '0' }
        - { name: 'net.core.somaxconn', value: '65535' }
    
    - name: 安装常用工具
      yum:
        name:
          - vim
          - htop
          - iotop
          - net-tools
          - lsof
          - strace
          - tcpdump
          - curl
          - wget
          - git
          - jq
          - tree
          - tmux
        state: present
    
    - name: 配置系统限制
      template:
        src: limits.conf.j2
        dest: /etc/security/limits.conf
    
    - name: 配置SSH安全
      lineinfile:
        path: /etc/ssh/sshd_config
        regexp: "{{ item.regexp }}"
        line: "{{ item.line }}"
      loop:
        - { regexp: '^#?PermitRootLogin', line: 'PermitRootLogin prohibit-password' }
        - { regexp: '^#?PasswordAuthentication', line: 'PasswordAuthentication no' }
        - { regexp: '^#?MaxAuthTries', line: 'MaxAuthTries 3' }
        - { regexp: '^#?ClientAliveInterval', line: 'ClientAliveInterval 300' }
      notify: restart sshd
    
    - name: 配置Ansible用户
      user:
        name: deploy
        groups: wheel
        shell: /bin/bash
        create_home: yes
    
    - name: 部署SSH公钥
      authorized_key:
        user: deploy
        key: "{{ lookup('file', '~/.ssh/id_rsa.pub') }}"
  
  handlers:
    - name: restart chrony
      systemd: name=chronyd state=restarted
    
    - name: restart sshd
      systemd: name=sshd state=restarted
```

### 2.3 Docker部署Playbook

```yaml
# roles/docker/tasks/main.yml
---
- name: 安装Docker依赖
  yum:
    name:
      - yum-utils
      - device-mapper-persistent-data
      - lvm2
    state: present

- name: 添加Docker仓库
  yum_repository:
    name: docker-ce
    description: Docker CE Repository
    baseurl: https://download.docker.com/linux/centos/$releasever/$basearch/stable
    gpgcheck: yes
    gpgkey: https://download.docker.com/linux/centos/gpg

- name: 安装Docker
  yum:
    name:
      - docker-ce
      - docker-ce-cli
      - containerd.io
      - docker-compose-plugin
    state: present

- name: 配置Docker daemon
  template:
    src: daemon.json.j2
    dest: /etc/docker/daemon.json

- name: 启动Docker
  systemd:
    name: docker
    state: started
    enabled: yes
```

```json
// roles/docker/templates/daemon.json.j2
{
  "data-root": "/data/docker",
  "storage-driver": "overlay2",
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m",
    "max-file": "3"
  },
  "registry-mirrors": [
    "https://mirror.ccs.tencentyun.com"
  ],
  "insecure-registries": [
    "harbor.internal.com"
  ],
  "max-concurrent-downloads": 10,
  "max-concurrent-uploads": 5,
  "default-ulimits": {
    "nofile": {
      "Name": "nofile",
      "Hard": 65535,
      "Soft": 65535
    }
  }
}
```

---

## 三、Terraform基础设施

### 3.1 阿里云ECS集群

```hcl
# main.tf - 阿里云ECS集群
terraform {
  required_providers {
    alicloud = {
      source  = "aliyun/alicloud"
      version = "~> 1.200"
    }
  }
  backend "oss" {
    bucket = "terraform-state-prod"
    key    = "k8s-cluster/terraform.tfstate"
    region = "cn-hangzhou"
  }
}

provider "alicloud" {
  region = var.region
}

# VPC
resource "alicloud_vpc" "main" {
  vpc_name   = "production-vpc"
  cidr_block = "10.0.0.0/16"
}

# 可用区
data "alicloud_zones" "available" {
  available_resource_creation = "VSwitch"
}

# 交换机
resource "alicloud_vswitch" "web" {
  count        = 3
  vpc_id       = alicloud_vpc.main.id
  cidr_block   = "10.0.${count.index + 1}.0/24"
  zone_id      = data.alicloud_zones.available.zones[count.index % 3].id
  vswitch_name = "web-subnet-${count.index + 1}"
}

# 安全组
resource "alicloud_security_group" "k8s" {
  name   = "k8s-sg"
  vpc_id = alicloud_vpc.main.id
}

resource "alicloud_security_group_rule" "allow_http" {
  type              = "ingress"
  ip_protocol       = "tcp"
  nic_type          = "intranet"
  policy            = "accept"
  port_range        = "80/80"
  security_group_id = alicloud_security_group.k8s.id
  cidr_ip           = "0.0.0.0/0"
}

resource "alicloud_security_group_rule" "allow_https" {
  type              = "ingress"
  ip_protocol       = "tcp"
  nic_type          = "intranet"
  policy            = "accept"
  port_range        = "443/443"
  security_group_id = alicloud_security_group.k8s.id
  cidr_ip           = "0.0.0.0/0"
}

# K8s Master节点
resource "alicloud_instance" "k8s_master" {
  count                = 3
  instance_name        = "k8s-master-${count.index + 1}"
  host_name            = "k8s-master-${count.index + 1}"
  instance_type        = "ecs.g7.2xlarge"  # 8C/32G
  image_id             = "centos_7_9_x64_20G_alibase_20230816.vhd"
  security_groups      = [alicloud_security_group.k8s.id]
  vswitch_id           = alicloud_vswitch.web[count.index % 3].id
  system_disk_category = "cloud_essd"
  system_disk_size     = 100
  system_disk_performance_level = "PL1"
  key_name             = alicloud_key_pair.deploy.key_name
  
  tags = {
    Role     = "k8s-master"
    Cluster  = "production"
  }
}

# K8s Worker节点
resource "alicloud_instance" "k8s_worker" {
  count                = 5
  instance_name        = "k8s-worker-${count.index + 1}"
  host_name            = "k8s-worker-${count.index + 1}"
  instance_type        = count.index < 3 ? "ecs.c7.4xlarge" : "ecs.g7.8xlarge"
  image_id             = "centos_7_9_x64_20G_alibase_20230816.vhd"
  security_groups      = [alicloud_security_group.k8s.id]
  vswitch_id           = alicloud_vswitch.web[count.index % 3].id
  system_disk_category = "cloud_essd"
  system_disk_size     = 100
  key_name             = alicloud_key_pair.deploy.key_name
  
  tags = {
    Role     = "k8s-worker"
    Cluster  = "production"
  }
}

# RDS MySQL
resource "alicloud_db_instance" "mysql" {
  engine               = "MySQL"
  engine_version       = "8.0"
  instance_type        = "rds.mysql.s3.large"  # 8C/32G
  instance_storage     = 500
  instance_charge_type = "Postpaid"
  instance_name        = "production-mysql"
  vswitch_id           = alicloud_vswitch.web[0].id
  security_ips         = ["10.0.0.0/16"]
  
  db_instance_storage_type = "cloud_essd"
  db_instance_disk_category = "cloud_essd"
  
  tags = {
    Role = "database"
  }
}

# Redis
resource "alicloud_kvstore_instance" "redis" {
  db_instance_name = "production-redis"
  instance_class   = "redis.master.small.default"
  instance_type    = "Redis"
  engine_version   = "7.0"
  vswitch_id       = alicloud_vswitch.web[0].id
  security_ips     = ["10.0.0.0/16"]
  
  tags = {
    Role = "cache"
  }
}
```

### 3.2 变量和输出

```hcl
# variables.tf
variable "region" {
  description = "阿里云区域"
  default     = "cn-hangzhou"
}

variable "environment" {
  description = "环境"
  default     = "production"
}

# outputs.tf
output "vpc_id" {
  value = alicloud_vpc.main.id
}

output "master_ips" {
  value = alicloud_instance.k8s_master[*].private_ip
}

output "worker_ips" {
  value = alicloud_instance.k8s_worker[*].private_ip
}

output "rds_endpoint" {
  value = alicloud_db_instance.mysql.connection_string
}

output "redis_endpoint" {
  value = alicloud_kvstore_instance.redis.connection_domain
}
```

---

## 四、Makefile自动化

```makefile
# Makefile
.PHONY: help init plan apply destroy

help:
	@echo "用法:"
	@echo "  make init          初始化Terraform"
	@echo "  make plan          预览变更"
	@echo "  make apply         应用变更"
	@echo "  make destroy       销毁资源"
	@echo "  make ansible-base  运行基础配置"
	@echo "  make ansible-docker 部署Docker"

init:
	cd terraform && terraform init

plan:
	cd terraform && terraform plan

apply:
	cd terraform && terraform apply -auto-approve

destroy:
	cd terraform && terraform destroy -auto-approve

ansible-base:
	cd ansible && ansible-playbook -i inventory/production/hosts playbooks/base.yml

ansible-docker:
	cd ansible && ansible-playbook -i inventory/production/hosts playbooks/docker.yml

ansible-all:
	cd ansible && ansible-playbook -i inventory/production/hosts playbooks/site.yml

# 批量运维命令
ansible-ping:
	cd ansible && ansible all -m ping -i inventory/production/hosts

ansible-disk:
	cd ansible && ansible all -m shell -a "df -h" -i inventory/production/hosts

ansible-reboot:
	cd ansible && ansible all -m reboot -i inventory/production/hosts
```

---

> 本项目基于25个语雀知识库(2699篇,584万字)编写
