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
        # [注意] 配置SSH安全前，需先分发密钥:
        # for ip in $(cat ips.txt); do ssh-copy-id root@${ip}; done
        # 确保密钥认证可用后再禁用密码登录
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
      version = "~> 2.0"
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
  image_id             = "rockylinux_9_x64_20G_alibase_20230816.vhd"
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
  image_id             = "rockylinux_9_x64_20G_alibase_20230816.vhd"
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
	cd terraform && terraform apply -auto-approve  # [注意] 生产环境应先执行terraform plan并人工审批

destroy:
	cd terraform && terraform destroy -auto-approve

ansible-base:
	cd ansible && ansible-playbook -i inventory/production/hosts playbooks/base.yml

ansible-docker:
	cd ansible && ansible-playbook -i inventory/production/hosts playbooks/docker.yml

ansible-all:
	cd ansible && ansible-playbook -i inventory/production/hosts playbooks/site.yml


---

> ⚠️ **安全声明**: 本文档中的密码(如${MYSQL_ROOT_PASSWORD}、${HARBOR_ADMIN_PASSWORD}等)均为示例占位符。
> 生产环境必须使用密钥管理工具(Vault/K8s Secrets/环境变量)管理敏感信息，
> 切勿将真实密码硬编码在配置文件或脚本中。

## 四、Ansible高级用法

### 4.1 Ansible Vault加密

```bash
# 创建加密文件
ansible-vault create secrets.yml

# 编辑加密文件
ansible-vault edit secrets.yml

# 运行时解密
ansible-playbook site.yml --ask-vault-pass

# 使用密码文件
ansible-playbook site.yml --vault-password-file=.vault_pass

# 加密单个变量
ansible-vault encrypt_string 'MyS3cretP@ss' --name 'db_password'
```

```yaml
# secrets.yml (加密后)
db_password: !vault |
  $ANSIBLE_VAULT;1.1;AES256
  3835613...
api_key: !vault |
  $ANSIBLE_VAULT;1.1;AES256
  616263...
```

### 4.2 Ansible Galaxy角色管理

```bash
# 安装社区角色
ansible-galaxy install geerlingguy.docker
ansible-galaxy install geerlingguy.mysql
ansible-galaxy install geerlingguy.redis

# 安装 collections
ansible-galaxy collection install community.general
ansible-galaxy collection install kubernetes.core

# 列出已安装
ansible-galaxy list

# requirements文件
cat > requirements.yml
roles:
  - src: geerlingguy.docker
    version: "6.1.0"
  - src: geerlingguy.mysql
    version: "4.0.0"
collections:
  - name: community.general
    version: ">=7.0.0"
```

### 4.3 动态Inventory

```python
#!/usr/bin/env python3
# dynamic_inventory.py - 从CMDB获取主机清单
import json
import urllib.request

CMDB_URL = "http://cmdb.internal.com/api/v1/hosts"

def get_inventory():
    req = urllib.request.Request(CMDB_URL)
    resp = urllib.request.urlopen(req)
    hosts = json.loads(resp.read().decode())
    
    inventory = {
        "all": {
            "hosts": {},
            "vars": {
                "ansible_user": "deploy",
                "ansible_become": True
            }
        },
        "_meta": {"hostvars": {}}
    }
    
    for host in hosts:
        hostname = host["hostname"]
        group = host.get("group", "ungrouped")
        
        if group not in inventory:
            inventory[group] = {"hosts": []}
        inventory[group]["hosts"].append(hostname)
        inventory["_meta"]["hostvars"][hostname] = {
            "ansible_host": host["ip"],
            "role": host.get("role", ""),
        }
    
    return inventory

if __name__ == "__main__":
    print(json.dumps(get_inventory(), indent=2))
```

### 4.4 Callback插件

```yaml
# callback_plugins/slack_notify.py
from ansible.plugins.callback import CallbackBase
import urllib.request
import json

class CallbackModule(CallbackBase):
    CALLBACK_VERSION = 2.0
    CALLBACK_TYPE = 'notification'
    CALLBACK_NAME = 'slack'
    
    def __init__(self):
        super().__init__()
        self.webhook_url = "https://hooks.slack.com/services/xxx"
    
    def v2_playbook_on_stats(self, stats):
        hosts = sorted(stats.processed.keys())
        summary = []
        for h in hosts:
            s = stats.summarize(h)
            summary.append(f"{h}: ok={s['ok']} changed={s['changed']} failures={s['failures']}")
        
        msg = f"Ansible Playbook完成\n" + "\n".join(summary)
        
        data = json.dumps({"text": msg}).encode()
        req = urllib.request.Request(self.webhook_url, data=data, headers={"Content-Type": "application/json"})
        urllib.request.urlopen(req)
```

### 4.5 性能优化

```ini
# ansible.cfg
[defaults]
# 并行执行
forks = 50

# SSH复用
ssh_args = -o ControlMaster=auto -o ControlPersist=60s

# 禁用SCP(使用s3fs)
transfer_method = sftp

# 缓存Fact
gathering = smart
fact_caching = jsonfile
fact_caching_connection = /tmp/ansible_facts
fact_caching_timeout = 86400

# 日志
log_path = /var/log/ansible.log

[ssh_connection]
# pipelining减少SSH连接数
pipelining = True

# 控制端口
control_path = /tmp/ansible-%%h-%%r

# SSH超时
ssh_timeout = 30
```

---

## 五、Terraform高级用法

### 5.1 Module化

```hcl
# modules/ecs-cluster/main.tf
variable "cluster_name" { type = string }
variable "node_count" { type = number }
variable "instance_type" { type = string }

resource "alicloud_instance" "node" {
  count                = var.node_count
  instance_name        = "${var.cluster_name}-node-${count.index + 1}"
  instance_type        = var.instance_type
  # ...
}

output "node_ips" {
  value = alicloud_instance.node[*].private_ip
}

# 使用module
module "k8s_cluster" {
  source = "./modules/ecs-cluster"
  
  cluster_name = "production"
  node_count   = 5
  instance_type = "ecs.c7.4xlarge"
}
```

### 5.2 Workspace管理环境

```bash
# 创建环境
terraform workspace new staging
terraform workspace new production

# 切换环境
terraform workspace select staging

# 根据环境设置变量
terraform apply -var="environment=staging" -var="node_count=3"
terraform apply -var="environment=production" -var="node_count=5"
```

### 5.3 State管理

```hcl
# 后端配置(阿里云OSS)
terraform {
  backend "oss" {
    bucket = "terraform-state-prod"
    key    = "k8s-cluster/terraform.tfstate"
    region = "cn-hangzhou"
    encrypt = true
    tablestore_endpoint = "https://tf-state-lock.cn-hangzhou.ots.aliyuncs.com"
    tablestore_table = "terraform_lock"
  }
}
```

### 5.4 导入现有资源

```bash
# 导入现有ECS实例
terraform import alicloud_instance.existing i-xxxxxxxxxxxx

# 导入现有VPC
terraform import alicloud_vpc.existing vpc-xxxxxxxxxxxx
```

---

## 六、真实故障案例

### 案例1: Ansible并发导致目标机SSH被封

**故障**: 200台机器同时执行，部分机器SSH连接被防火墙封禁

**原因**: 大量并发SSH连接触发了fail2ban规则

**解决**:
```ini
# ansible.cfg
[defaults]
forks = 20  # 从50降到20

[ssh_connection]
# 添加随机延迟
pipelining = True
# 控制连接速率
```

```yaml
# 使用linear策略控制执行速度
- hosts: all
  serial: "20%"  # 每批20%
  strategy: linear
  tasks:
    - name: 执行任务
      command: /opt/scripts/maintenance.sh
```

### 案例2: Terraform State锁死

**故障**: Terraform apply中断后，state被锁定无法操作

**解决**:
```bash
# 查看锁信息
terraform force-unlock <lock-id>

# 或者手动清理
# 阿里云OTS表中删除锁记录
```

### 案例3: Ansible幂等性失效

**故障**: 重复执行playbook，每次都产生changed

**解决**:
```yaml
# 使用creates/removes参数
- name: 安装软件
  yum:
    name: docker-ce
    state: present
  register: docker_install

- name: 配置Docker
  template:
    src: daemon.json.j2
    dest: /etc/docker/daemon.json
  notify: restart docker

# 使用when条件避免重复执行
- name: 初始化数据库
  command: /opt/scripts/init_db.sh
  args:
    creates: /opt/.db_initialized  # 文件存在则跳过
```

---

## 七、成本估算

| 项目 | 月成本 |
|------|--------|
| Ansible控制节点(4C/8G) | 400元 |
| Terraform状态存储(OSS) | 10元 |
| Jenkins(CI/CD) | 800元 |
| GitLab(代码仓库) | 600元 |
| **总计** | **1,810元/月** |

---



## 踩坑记录

### Q1: Ansible Playbook超时
**原因**: SSH连接不稳定或目标机负载高
**解决**: 增大timeout参数，配置pipelining减少连接次数

### Q2: Terraform state文件损坏
**原因**: 多人同时操作state文件
**解决**: 配置远程backend(S3/OSS)并启用state locking

### Q3: Ansible角色依赖冲突
**原因**: 多个role依赖不同版本的同一个role
**解决**: 在meta/main.yml中明确指定依赖版本

### Q4: Terraform apply报"provider configuration not present"
**原因**: 模块中未传递provider配置
**解决**: 在模块调用时显式传递providers参数

### Q5: Ansible vault密码泄露
**原因**: vault密码文件权限过宽
**解决**: chmod 600 vault密码文件，不要提交到git

> 本项目基于官方文档、技术博客和社区实践深度学习编写

---

## 八、真实故障案例

### 案例1: Playbook执行超时导致批量失败

**故障现象**: 执行base.yml时，50台服务器中20台报"Timeout"错误

**根因分析**:
- forks设置过大(100)，SSH连接数超过sshd MaxStartups限制
- 部分服务器网络延迟高(跨可用区)
- 目标机磁盘IO满导致响应慢

**排查过程**:
```bash
# 查看超时详情
ansible-playbook -vvv playbooks/base.yml 2>&1 | grep -i timeout

# 检查SSH连接数
ansible all -m shell -a "ss -s | grep estab"

# 检查磁盘IO
ansible all -m shell -a "iostat -x 1 3 | grep -A2 sda"
```

**解决方案**:
```ini
# ansible.cfg
[defaults]
forks = 20                    # 降低并发数
timeout = 30                  # SSH超时
gather_timeout = 60           # Facts收集超时
[ssh_connection]
pipelining = True
ssh_args = -o ControlMaster=auto -o ControlPersist=60s -o ConnectTimeout=10
```

```yaml
# 使用serial分批执行
- hosts: all
  serial: 10                  # 每批10台
  max_fail_percentage: 10     # 允许10%失败
  any_errors_fatal: false
  tasks:
    - name: 基础配置
      import_role:
        name: common
```

---

### 案例2: Terraform State损坏导致资源丢失

**故障现象**: `terraform plan`报错"state file is corrupted"，且部分资源在云上已创建但state中无记录

**根因分析**: CI/CD并发执行terraform apply，导致state文件写入冲突

**解决方案**:
```bash
# 1. 备份当前state
cp terraform.tfstate terraform.tfstate.bak.$(date +%s)

# 2. 查找云上已有资源
aliyun ecs DescribeInstances --RegionId cn-hangzhou | jq '.Instances.Instance[].InstanceId'

# 3. 使用terraform import逐个导入
terraform import alicloud_instance.k8s_master[0] i-xxxxxxxxxxxx
terraform import alicloud_instance.k8s_master[1] i-yyyyyyyyyyyy
terraform import alicloud_vpc.main vpc-zzzzzzzzzzzz

# 4. 验证一致性
terraform plan -no-color | grep -E "(create|destroy|update)"
```

**预防措施**:
```hcl
# 后端配置启用状态锁
terraform {
  backend "oss" {
    bucket = "terraform-state-prod"
    key    = "k8s-cluster/terraform.tfstate"
    region = "cn-hangzhou"
    encrypt = true
    tablestore_endpoint = "https://tf-state-lock.cn-hangzhou.ots.aliyuncs.com"
    tablestore_table = "terraform_lock"
  }
}
```

---

### 案例3: Jinja2模板渲染变量未定义

**故障现象**: Playbook报错`'ansible.utils.missing mandatory variable'`，部分模板生成的配置为空

**根因分析**: group_vars中缺少某个变量定义，且模板中未使用default过滤器

**排查过程**:
```bash
# 检查变量定义
ansible-inventory --vars --list | jq '.all.vars.db_port'

# 使用debug输出变量
ansible-playbook -e "ansible_debug=true" --step playbooks/mysql.yml
```

**解决方案**:
```yaml
# templates/chrony.conf.j2 (修复前)
server {{ ntp_server }} iburst

# templates/chrony.conf.j2 (修复后)
server {{ ntp_server | default('ntp.aliyun.com') }} iburst
{% for server in ntp_servers | default(['ntp.aliyun.com']) %}
server {{ server }} iburst
{% endfor %}
```

```yaml
# group_vars/all.yml - 添加默认值
ntp_servers:
  - ntp.aliyun.com
  - ntp1.aliyun.com
ntp_server: "{{ ntp_servers[0] }}"
db_port: 3306
```

---

### 案例4: Provider版本不兼容

**故障现象**: Terraform apply报错`provider does not support resource alicloud_instance`

**根因分析**: alicloud provider版本从1.200升级到2.0，部分资源属性名变更

**解决方案**:
```hcl
# 锁定Provider版本
terraform {
  required_providers {
    alicloud = {
      source  = "aliyun/alicloud"
      version = "= 1.200.0"     # 精确锁定版本
    }
  }
}

# 或者使用兼容版本范围
terraform {
  required_providers {
    alicloud = {
      source  = "aliyun/alicloud"
      version = ">= 1.180, < 2.0"  # 使用兼容范围
    }
  }
}
```

```bash
# 版本升级迁移步骤
terraform state mv alicloud_instance.old alicloud_instance.new
terraform plan -upgrade
```

---

### 案例5: 角色依赖冲突

**故障现象**: `ansible-galaxy install`报错角色版本冲突，已有角色版本不满足requirements

**根因分析**: 项目依赖geerlingguy.docker 6.0，但另一个role依赖geerlingguy.docker 5.0

**解决方案**:
```yaml
# requirements.yml - 明确指定所有依赖版本
roles:
  - src: geerlingguy.docker
    version: "6.1.0"
    name: docker
  - src: geerlingguy.mysql
    version: "4.0.0"
    name: mysql

# 清除旧版本重新安装
rm -rf roles/geerlingguy.docker
ansible-galaxy install -r requirements.yml --force
```

```bash
# 查看已安装角色版本
ansible-galaxy list | grep docker

# 检查角色依赖树
ansible-galaxy info geerlingguy.docker | grep dependencies
```

---

### 案例6: include_tasks导入顺序错误

**故障现象**: Playbook执行时依赖的服务尚未安装，导致配置失败

**根因分析**: tasks目录下文件按字母顺序加载，实际执行顺序不符合依赖关系

**解决方案**:
```yaml
# playbooks/site.yml - 明确指定执行顺序
---
- import_playbook: base.yml
- import_playbook: docker.yml
- import_playbook: k8s.yml
- import_playbook: app.yml
- import_playbook: monitoring.yml

# 使用pre_tasks和post_tasks
- hosts: all
  pre_tasks:
    - name: 确认执行环境
      assert:
        that: ansible_os_family == "RedHat"
        fail_msg: "仅支持CentOS/RHEL系统"
  roles:
    - common
    - docker
  post_tasks:
    - name: 验证部署结果
      uri:
        url: "http://localhost:2375/version"
      register: docker_check
      until: docker_check.status == 200
      retries: 5
      delay: 10
```

---

### 案例7: SSH连接不稳定导致批量操作中断

**故障现象**: 200台机器执行维护脚本，中途30台SSH断连，playbook中断

**根因分析**:
- 目标机sshd MaxSessions限制为10
- 网络抖动导致ControlMaster连接断开
- 缺少重试机制

**解决方案**:
```ini
# ansible.cfg
[ssh_connection]
# SSH连接复用
ssh_args = -o ControlMaster=auto -o ControlPersist=300s -o ServerAliveInterval=30 -o ServerAliveCountMax=3
# 增加重试次数
retries = 5
# 连接超时
timeout = 30
```

```yaml
# 使用strategy: free提高容错性
- hosts: all
  strategy: free
  serial: "25%"
  max_fail_percentage: 15
  any_errors_fatal: false
  tasks:
    - name: 维护操作
      block:
        - name: 执行脚本
          script: scripts/maintenance.sh
          register: result
          retries: 3
          delay: 5
          until: result.rc == 0
      rescue:
        - name: 记录失败主机
          lineinfile:
            path: /tmp/failed_hosts.log
            line: "{{ inventory_hostname }}"
          delegate_to: localhost
```

---

### 案例8: 环境配置混淆导致生产事故

**故障现象**: staging环境的playbook误执行到生产环境，覆盖了生产配置

**根因分析**: inventory目录结构不清晰，缺少环境校验机制

**解决方案**:
```yaml
# playbooks/site.yml - 添加环境校验
---
- hosts: all
  vars:
    target_env: "{{ group_names | intersect(['production', 'staging', 'dev']) | first }}"
  pre_tasks:
    - name: 环境确认
      pause:
        prompt: |
          ⚠️  即将在 {{ target_env }} 环境执行
          主机数: {{ inventory_hostname | length }}
          请输入环境名称确认: {{ target_env }}
      register: confirm
      when: target_env == "production"
      delegate_to: localhost

    - name: 校验确认结果
      fail:
        msg: "生产环境操作未确认，终止执行"
      when:
        - target_env == "production"
        - confirm.user_input | default('') != target_env
```

```ini
# ansible.cfg - 分环境配置
[defaults]
inventory = inventory/production/
vault_password_file = .vault_pass_prod

# 通过环境变量覆盖
# ANSIBLE_INVENTORY=inventory/staging/ ansible-playbook site.yml
```

---

## 九、Ansible调优参数大全

### 9.1 forks并发控制

```ini
# ansible.cfg
[defaults]
# 并行执行数(默认5，建议20-50)
forks = 50

# 针对不同网络环境调整
# 内网环境
# forks = 100

# 跨可用区
# forks = 30

# 跨地域
# forks = 10
```

```yaml
# playbooks中动态控制并发
- hosts: webservers
  serial: "20%"          # 每批执行20%的主机
  gather_facts: true
  
  pre_tasks:
    - name: 计算批次
      set_fact:
        batch_size: "{{ groups['webservers'] | length * 0.2 | int }}"
  
  tasks:
    - name: 滚动更新
      uri:
        url: "http://{{ inventory_hostname }}:8080/actuator/shutdown"
        method: POST
      delegate_to: localhost
```

### 9.2 Pipelining优化

```ini
# ansible.cfg
[ssh_connection]
# 开启pipelining减少SSH连接次数(默认关闭)
pipelining = True

# 前提条件:
# 1. 目标机/etc/sudoers中需要配置:
#   Defaults !requiretty

# 2. 或者在playbook中禁用requiretty
# become: yes
# become_flags: '-H -S -n'
```

```yaml
# 对比开启前后的执行效率
# 开启前: 每个task建立一次SSH连接
# 开启后: 整个playbook共用一次SSH连接

# 性能测试
time ansible-playbook -i inventory/production/hosts playbooks/base.yml
# 开启pipelining: 2分30秒
# 关闭pipelining: 8分45秒
```

### 9.3 Fact缓存配置

```ini
# ansible.cfg
[defaults]
# Fact收集策略: smart(已收集过的跳过)
gathering = smart

# Fact缓存后端: jsonfile/redis/memcached
fact_caching = redis

# Redis缓存配置
fact_caching_connection = localhost:6379:0:ansible_facts

# 缓存超时(秒): 86400=24小时
fact_caching_timeout = 86400

# JSON文件缓存(备选方案)
# fact_caching = jsonfile
# fact_caching_connection = /tmp/ansible_facts
# fact_caching_timeout = 86400
```

```yaml
# 仅在需要时收集Facts
- hosts: all
  gather_facts: no          # 禁用自动收集
  tasks:
    - name: 手动收集特定Facts
      setup:
        filter: ansible_distribution*
      
    - name: 使用自定义Facts
      set_fact:
        custom_fact: "{{ lookup('file', '/etc/custom_fact.txt') }}"
```

### 9.4 异步任务配置

```yaml
# 异步执行长时间任务
- hosts: all
  tasks:
    # 异步执行耗时脚本
    - name: 执行数据库备份
      command: /opt/scripts/db_backup.sh
      async: 3600          # 最大运行时间(秒)
      poll: 0              # 不等待结果(防火)
      register: backup_job

    - name: 等待备份完成
      async_status:
        jid: "{{ backup_job.ansible_job_id }}"
      register: job_result
      until: job_result.finished
      retries: 60
      delay: 60            # 每分钟检查一次

    # 并行执行多个异步任务
    - name: 批量重启服务
      command: systemctl restart {{ item }}
      loop:
        - nginx
        - php-fpm
        - php-worker
      async: 120
      poll: 0
      register: restart_jobs

    - name: 等待所有重启完成
      async_status:
        jid: "{{ item.ansible_job_id }}"
      loop: "{{ restart_jobs.results }}"
      register: restart_results
      until: restart_results.results | map(attribute='finished') | select('equalto', true) | list | length == 3
      retries: 10
      delay: 15
```

### 9.5 SSH连接优化

```ini
# ansible.cfg
[ssh_connection]
# SSH复用(减少连接建立时间)
ssh_args = -o ControlMaster=auto -o ControlPersist=300s -o ControlPath=/tmp/ansible-ssh-%h-%p-%r

# 加速传输
transfer_method = piped    # piped比sftp快(默认sftp)

# 压缩传输
ssh_args += -o Compression=yes

# 控制端口(避免冲突)
control_path = /tmp/ansible-%%h-%%r
```

### 9.6 完整优化配置示例

```ini
# ansible.cfg - 生产环境优化配置
[defaults]
inventory = ./inventory/production/
remote_user = deploy
private_key_file = ~/.ssh/deploy_key
host_key_checking = False

# 并发优化
forks = 50
timeout = 30

# Fact缓存
gathering = smart
fact_caching = redis
fact_caching_connection = localhost:6379:0:ansible_facts
fact_caching_timeout = 86400

# 日志
log_path = /var/log/ansible.log
log_level = INFO

# 回调插件
stdout_callback = yaml
callback_whitelist = timer, profile_tasks

# Vault
vault_password_file = .vault_pass

[ssh_connection]
pipelining = True
ssh_args = -o ControlMaster=auto -o ControlPersist=300s -o ServerAliveInterval=30
control_path = /tmp/ansible-%%h-%%r
ssh_timeout = 30
retries = 3

[persistent_connection]
connect_timeout = 30
command_timeout = 30
```

---

## 十、Terraform调优

### 10.1 Backend远程状态管理

```hcl
# backend.tf - 多环境状态管理
terraform {
  backend "oss" {
    # 生产环境
    bucket = "terraform-state-prod"
    key    = "production/k8s-cluster/terraform.tfstate"
    region = "cn-hangzhou"
    encrypt = true
    
    # 状态锁(使用TableStore)
    tablestore_endpoint = "https://tf-state-lock.cn-hangzhou.ots.aliyuncs.com"
    tablestore_table = "terraform_lock"
  }
}
```

```bash
# 多环境状态管理
# 创建staging状态
terraform workspace new staging
terraform apply -var="environment=staging"

# 创建production状态
terraform workspace new production
terraform apply -var="environment=production"

# 列出所有workspace
terraform workspace list

# 查看当前workspace
terraform workspace show
```

### 10.2 State锁机制

```hcl
# 自定义锁配置
terraform {
  backend "oss" {
    bucket = "terraform-state-prod"
    key    = "k8s-cluster/terraform.tfstate"
    region = "cn-hangzhou"
    encrypt = true
    
    # 锁超时时间(秒)
    lock_method = "POST"
    unlock_method = "DELETE"
  }
}
```

```bash
# 锁管理命令
# 查看锁状态
terraform state pull | jq '.lock_info'

# 强制解锁(谨慎使用)
terraform force-unlock <LOCK_ID>

# 检查锁是否被持有
aliyun ots BatchGetRow --instance-name tf-state-lock --tables terraform_lock
```

### 10.3 模块化设计

```hcl
# modules/vpc/main.tf - VPC模块
variable "vpc_name" { type = string }
variable "cidr_block" { type = string }
variable "az_count" { type = number, default = 3 }

resource "alicloud_vpc" "this" {
  vpc_name   = var.vpc_name
  cidr_block = var.cidr_block
}

resource "alicloud_vswitch" "this" {
  count        = var.az_count
  vpc_id       = alicloud_vpc.this.id
  cidr_block   = cidrsubnet(var.vpc_cidr, 8, count.index)
  zone_id      = data.alicloud_zones.available.zones[count.index % var.az_count].id
}

output "vpc_id" { value = alicloud_vpc.this.id }
output "vswitch_ids" { value = alicloud_vswitch.this[*].id }
```

```hcl
# modules/ecs-cluster/main.tf - ECS集群模块
variable "cluster_name" { type = string }
variable "vswitch_ids" { type = list(string) }
variable "master_count" { type = number, default = 3 }
variable "worker_count" { type = number, default = 5 }
variable "master_instance_type" { type = string, default = "ecs.g7.2xlarge" }
variable "worker_instance_type" { type = string, default = "ecs.c7.4xlarge" }

resource "alicloud_instance" "master" {
  count                = var.master_count
  instance_name        = "${var.cluster_name}-master-${count.index + 1}"
  instance_type        = var.master_instance_type
  vswitch_id           = var.vswitch_ids[count.index % length(var.vswitch_ids)]
  # ... 其他配置
}

resource "alicloud_instance" "worker" {
  count                = var.worker_count
  instance_name        = "${var.cluster_name}-worker-${count.index + 1}"
  instance_type        = var.worker_instance_type
  vswitch_id           = var.vswitch_ids[count.index % length(var.vswitch_ids)]
  # ... 其他配置
}
```

```hcl
# 根模块调用
module "vpc" {
  source = "./modules/vpc"
  
  vpc_name   = "production-vpc"
  cidr_block = "10.0.0.0/16"
  az_count   = 3
}

module "k8s_cluster" {
  source = "./modules/ecs-cluster"
  
  cluster_name    = "production"
  vswitch_ids     = module.vpc.vswitch_ids
  master_count    = 3
  worker_count    = 5
}
```

### 10.4 Workspace多环境管理

```hcl
# environments/staging/terraform.tfvars
environment     = "staging"
instance_type   = "ecs.c7.large"
master_count    = 1
worker_count    = 2
enable_monitoring = false

# environments/production/terraform.tfvars
environment     = "production"
instance_type   = "ecs.g7.2xlarge"
master_count    = 3
worker_count    = 5
enable_monitoring = true
```

```bash
# 使用不同workspace执行
terraform workspace select staging
terraform apply -var-file="environments/staging/terraform.tfvars"

terraform workspace select production
terraform apply -var-file="environments/production/terraform.tfvars"

# 查看workspace差异
terraform workspace show
terraform state list
```

### 10.5 性能优化

```hcl
# 并行执行优化
terraform {
  # 增加并行度(默认10)
  parallelism = 20
}

# 使用-target只变更指定资源
terraform apply -target=alicloud_instance.worker

# 使用-refresh=false跳过刷新(加速plan)
terraform plan -refresh=false

# 使用-auto-approve跳过确认
terraform apply -auto-approve  # [注意] 生产环境应先执行terraform plan并人工审批 -input=false
```

```bash
# 批量导入现有资源
terraform import \
  alicloud_instance.master[0] i-xxxxxxxxxxxx \
  alicloud_instance.master[1] i-yyyyyyyyyyyy \
  alicloud_instance.worker[0] i-zzzzzzzzzzzz

# 生成导入配置
terraform state show alicloud_instance.master[0]
```

---

## 十一、灾备方案

### 11.1 Ansible控制节点灾备

```bash
#!/bin/bash
# ansible_disaster_recovery.sh

set -euo pipefail

BACKUP_DIR="/backup/ansible"
DATE=$(date +%Y%m%d_%H%M%S)

echo "========== 1. 备份Ansible配置 =========="
mkdir -p $BACKUP_DIR/$DATE
cp -r /etc/ansible $BACKUP_DIR/$DATE/
cp -r ~/ansible-ops $BACKUP_DIR/$DATE/

echo "========== 2. 备份Vault密码 =========="
cp ~/.vault_pass $BACKUP_DIR/$DATE/vault_pass.bak

echo "========== 3. 备份SSH密钥 =========="
cp -r ~/.ssh/deploy_key* $BACKUP_DIR/$DATE/

echo "========== 4. 备份角色和Collections =========="
ansible-galaxy list --format json > $BACKUP_DIR/$DATE/roles.json
ansible-galaxy collection list --format json > $BACKUP_DIR/$DATE/collections.json

echo "========== 5. 推送到OSS =========="
ossutil cp -r $BACKUP_DIR/$DATE oss://backup-ansible/$DATE/ --force

echo "✅ Ansible配置备份完成: $BACKUP_DIR/$DATE"
```

### 11.2 Terraform State灾备

```bash
#!/bin/bash
# terraform_state_backup.sh

set -euo pipefail

BACKUP_BUCKET="terraform-state-backup"
DATE=$(date +%Y%m%d_%H%M%S)

echo "========== 备份所有State文件 =========="
# 列出所有workspace
for ws in $(terraform workspace list | grep -v '\*' | tr -d ' '); do
  terraform workspace select $ws
  
  # 备份state
  terraform state pull > /tmp/terraform-${ws}-${DATE}.tfstate
  
  # 上传到备份bucket
  ossutil cp /tmp/terraform-${ws}-${DATE}.tfstate \
    oss://$BACKUP_BUCKET/states/${ws}/${DATE}/terraform.tfstate
    
  echo "✅ 备份完成: $ws"
done

echo "========== 验证备份 =========="
ossutil ls oss://$BACKUP_BUCKET/states/
```

### 11.3 灾难恢复流程

```
灾难恢复流程:

1. 评估阶段 (0-30分钟)
   ├── 确认灾难范围
   ├── 评估数据完整性
   ├── 确定恢复目标(RTO/RPO)
   └── 通知相关人员

2. 基础设施恢复 (30分钟-2小时)
   ├── 恢复Terraform State
   ├── 执行terraform apply重建基础设施
   ├── 验证VPC/网络连通性
   └── 验证安全组/ACL配置

3. 应用恢复 (2-6小时)
   ├── 恢复Ansible控制节点
   ├── 拉取最新Playbook代码
   ├── 执行ansible-playbook重建配置
   ├── 恢复数据库(从备份)
   ├── 验证应用服务
   └── 验证数据一致性

4. 业务恢复 (6-12小时)
   ├── 切换DNS到新环境
   ├── 验证外部访问
   ├── 监控系统指标
   └── 通知业务方

5. 复盘阶段 (24-72小时)
   ├── 编写事故报告
   ├── 优化灾备流程
   ├── 更新文档
   └── 团队复盘会议
```

---

## 十二、成本估算

### 12.1 基础设施成本

| 资源类型 | 规格 | 数量 | 月成本(元) |
|---------|------|------|-----------|
| K8s Master ECS | ecs.g7.2xlarge (8C/32G) | 3 | 12,600 |
| K8s Worker ECS | ecs.c7.4xlarge (8C/16G) | 5 | 10,500 |
| RDS MySQL | mysql.s3.large (8C/32G) | 1 | 6,800 |
| Redis | redis.master.small.default | 1 | 1,200 |
| SLB负载均衡 | performance.share.s2.small | 2 | 800 |
| NAT网关 |增强型 | 1 | 500 |
| 带宽 |100Mbps | 1 | 3,000 |
| **子计** | | | **35,400** |

### 12.2 运维工具成本

| 工具/服务 | 用途 | 月成本(元) |
|----------|------|-----------|
| Ansible控制节点 | 配置管理 | 400 |
| Terraform State存储 | 基础设施管理 | 10 |
| Jenkins | CI/CD流水线 | 800 |
| GitLab | 代码仓库 | 600 |
| Harbor | 镜像仓库 | 300 |
| Prometheus+Grafana | 监控告警 | 500 |
| ELK Stack | 日志分析 | 1,200 |
| 堡垒机(JumpServer) | 运维审计 | 400 |
| **子计** | | **4,210** |

### 12.3 年度总成本

| 类别 | 月成本(元) | 年成本(元) |
|------|-----------|-----------|
| 基础设施 | 35,400 | 424,800 |
| 运维工具 | 4,210 | 50,520 |
| 备份存储 | 800 | 9,600 |
| 域名/证书 | 200 | 2,400 |
| **总计** | **40,610** | **487,320** |

---

## 十三、监控告警

### 13.1 Ansible执行监控

```yaml
# ansible-monitoring.yml
---
- name: Ansible执行监控
  hosts: all
  vars:
    prometheus_url: "http://prometheus.internal:9090"
  
  tasks:
    # 记录执行开始时间
    - name: 记录开始时间
      uri:
        url: "{{ prometheus_url }}/api/v1/write"
        method: POST
        body: |
          ansible_execution_start{host="{{ inventory_hostname }}", playbook="{{ playbook_name }}"} {{ ansible_date_time.epoch }}
    
    # 记录任务执行结果
    - name: 记录任务结果
      uri:
        url: "{{ prometheus_url }}/api/v1/write"
        method: POST
        body: |
          ansible_task_result{host="{{ inventory_hostname }}", task="{{ item.name }}", status="{{ item.status }}"} 1
      loop: "{{ ansible_facts }}"
```

### 13.2 Terraform执行监控

```bash
#!/bin/bash
# terraform_monitoring.sh

# 记录Terraform执行指标
PROMETHEUS_URL="http://prometheus.internal:9090"

# 记录apply耗时
START_TIME=$(date +%s)
terraform apply -auto-approve  # [注意] 生产环境应先执行terraform plan并人工审批 -input=false
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

# 推送指标
curl -X POST "$PROMETHEUS_URL/api/v1/write" \
  -d "terraform_apply_duration_seconds{environment=\"production\"} $DURATION"

# 记录变更资源数
CHANGE_COUNT=$(terraform plan -no-color 2>&1 | grep -c "to be")
curl -X POST "$PROMETHEUS_URL/api/v1/write" \
  -d "terraform_changes{environment=\"production\"} $CHANGE_COUNT"
```

### 13.3 告警规则配置

```yaml
# ansible-alerts.yml
groups:
  - name: ansible-alerts
    rules:
      # Ansible执行失败
      - alert: AnsiblePlaybookFailed
        expr: ansible_playbook_failure_total > 0
        for: 0m
        labels:
          severity: critical
        annotations:
          summary: "Ansible Playbook执行失败"
          
      # Terraform State锁超时
      - alert: TerraformStateLocked
        expr: terraform_state_lock_duration_seconds > 300
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Terraform State锁超时"
          
      # 基础设施漂移
      - alert: InfrastructureDrift
        expr: terraform_drift_detected > 0
        for: 0m
        labels:
          severity: critical
        annotations:
          summary: "基础设施配置漂移检测"
```

---

## 十四、运维SOP

### 14.1 日常运维SOP

```
每日运维检查清单:

09:00 - 系统健康检查
  ├── 检查所有服务状态
  │   ansible all -m shell -a "systemctl status nginx php-fpm"
  ├── 检查磁盘使用率
  │   ansible all -m shell -a "df -h | grep -v tmpfs"
  ├── 检查内存使用
  │   ansible all -m shell -a "free -h"
  └── 检查网络连通性
      ansible all -m ping

10:00 - 日志检查
  ├── 检查错误日志
  │   ansible all -m shell -a "tail -100 /var/log/nginx/error.log"
  ├── 检查安全日志
  │   ansible all -m shell -a "grep 'Failed password' /var/log/secure | tail -20"
  └── 检查应用日志
      ansible all -m shell -a "tail -100 /var/log/app/error.log"

14:00 - 性能监控
  ├── CPU使用率检查
  │   ansible all -m shell -a "top -bn1 | head -5"
  ├── IO等待检查
  │   ansible all -m shell -a "iostat -x 1 3 | tail -5"
  └── 网络连接检查
      ansible all -m shell -a "netstat -an | grep ESTABLISHED | wc -l"

17:00 - 备份验证
  ├── 验证数据库备份
  │   ansible dbservers -m shell -a "ls -lh /backup/mysql/"
  ├── 验证配置备份
  │   ansible all -m shell -a "ls -lh /backup/config/"
  └── 验证日志备份
      ansible all -m shell -a "ls -lh /backup/logs/"
```

### 14.2 变更发布SOP

```
变更发布流程:

1. 变更准备 (D-3天)
   ├── 编写变更方案
   ├── 代码评审(Code Review)
   ├── 测试环境验证
   ├── 回滚方案准备
   └── 审批流程

2. 变更执行 (D-0)
   ├── 通知相关方
   ├── 创建快照/备份
   ├── 执行Terraform变更
   │   terraform plan -out=tfplan
   │   terraform apply tfplan
   ├── 执行Ansible配置
   │   ansible-playbook -i inventory/production/hosts playbooks/app.yml
   ├── 验证变更结果
   └── 监控30分钟

3. 变更确认 (D+1天)
   ├── 业务验证
   ├── 性能对比
   ├── 监控告警检查
   └── 文档更新
```

### 14.3 故障处理SOP

```
故障处理流程:

1. 故障发现 (0-5分钟)
   ├── 监控告警触发
   ├── 用户反馈
   ├── 自动检测
   └── 通知值班人员

2. 故障定位 (5-30分钟)
   ├── 确认故障范围
   │   ansible all -m ping
   ├── 检查服务状态
   │   ansible all -m shell -a "systemctl status *"
   ├── 检查日志
   │   ansible all -m shell -a "journalctl -u nginx --since '30 min ago'"
   └── 检查网络
       ansible all -m shell -a "curl -I http://localhost"

3. 故障恢复 (30分钟-2小时)
   ├── 执行恢复脚本
   │   ansible-playbook -i inventory/production/hosts playbooks/recovery.yml
   ├── 验证恢复结果
   ├── 监控恢复后状态
   └── 通知业务方

4. 故障复盘 (24-72小时)
   ├── 编写故障报告
   ├── 根因分析(RCA)
   ├── 改进措施
   └── 预防方案
```

### 14.4 安全事件处理SOP

```
安全事件处理流程:

1. 事件检测 (0-15分钟)
   ├── 监控告警
   │   - SSH暴力破解
   │   - 异常登录
   │   - 恶意文件
   ├── 用户报告
   └── 漏洞扫描发现

2. 事件响应 (15-60分钟)
   ├── 隔离受影响主机
   │   ansible affected -m shell -a "firewall-cmd --panic-on"
   ├── 封禁攻击IP
   │   ansible all -m shell -a "iptables -A INPUT -s ATTACK_IP -j DROP"
   ├── 保留证据
   │   ansible affected -m fetch -a "src=/var/log/secure dest=./evidence/"
   └── 通知安全团队

3. 事件消除 (1-24小时)
   ├── 分析攻击向量
   ├── 清除恶意软件
   ├── 修复漏洞
   │   ansible-playbook playbooks/security-fix.yml
   ├── 重置泄露凭证
   └── 更新安全策略

4. 事件恢复 (24-72小时)
   ├── 恢复系统服务
   ├── 验证数据完整性
   ├── 监控异常行为
   └── 逐步恢复业务

5. 事件总结 (72小时后)
   ├── 编写事件报告
   ├── 更新应急预案
   ├── 安全培训
   └── 完善监控规则
```