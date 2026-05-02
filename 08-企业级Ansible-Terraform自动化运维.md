     1|# 企业级Ansible + Terraform自动化运维
     2|
     3|> 完整实现自动化运维体系，覆盖配置管理、基础设施即代码、批量运维、CI/CD集成
     4|
     5|---
     6|
     7|## 一、架构
     8|
     9|```
    10|┌─────────────────────────────────────────────────┐
    11|│                  运维控制中心                      │
    12|│  ┌──────────┐  ┌──────────┐  ┌──────────┐      │
    13|│  │ Ansible  │  │ Terraform│  │ Jenkins  │      │
    14|│  │ 配置管理  │  │ IaC      │  │ CI/CD    │      │
    15|│  └────┬─────┘  └────┬─────┘  └────┬─────┘      │
    16|└───────┼──────────────┼──────────────┼────────────┘
    17|        │              │              │
    18|        ▼              ▼              ▼
    19|   ┌─────────┐   ┌──────────┐  ┌──────────┐
    20|   │ 服务器   │   │ 云资源    │  │ 容器集群  │
    21|   │ 200+台  │   │ VPC/ECS  │  │ K8s      │
    22|   └─────────┘   └──────────┘  └──────────┘
    23|```
    24|
    25|---
    26|
    27|## 二、Ansible项目结构
    28|
    29|```
    30|ansible-ops/
    31|├── ansible.cfg
    32|├── inventory/
    33|│   ├── production/
    34|│   │   ├── hosts              # 主机清单
    35|│   │   └── group_vars/
    36|│   │       ├── all.yml        # 全局变量
    37|│   │       ├── webservers.yml
    38|│   │       ├── dbservers.yml
    39|│   │       └── cacheservers.yml
    40|│   └── staging/
    41|├── playbooks/
    42|│   ├── site.yml               # 主入口
    43|│   ├── base.yml               # 基础配置
    44|│   ├── docker.yml             # Docker部署
    45|│   ├── k8s.yml                # K8s部署
    46|│   ├── monitoring.yml         # 监控部署
    47|│   ├── mysql.yml              # MySQL部署
    48|│   └── security.yml           # 安全加固
    49|├── roles/
    50|│   ├── common/
    51|│   ├── docker/
    52|│   ├── k8s/
    53|│   ├── nginx/
    54|│   ├── mysql/
    55|│   ├── redis/
    56|│   ├── prometheus/
    57|│   └── security/
    58|├── collections/
    59|│   └── requirements.yml
    60|└── Makefile
    61|```
    62|
    63|### 2.1 主机清单
    64|
    65|```ini
    66|# inventory/production/hosts
    67|[all:vars]
    68|ansible_user=deploy
    69|ansible_become=yes
    70|ansible_python_interpreter=/usr/bin/python3
    71|ansible_ssh_private_key_file=~/.ssh/deploy_key
    72|
    73|[webservers]
    74|web-01 ansible_host=10.10.10.21
    75|web-02 ansible_host=10.10.10.22
    76|web-03 ansible_host=10.10.10.23
    77|
    78|[dbservers]
    79|db-01 ansible_host=10.10.30.11
    80|db-02 ansible_host=10.10.30.12
    81|db-03 ansible_host=10.10.30.13
    82|
    83|[cacheservers]
    84|cache-01 ansible_host=10.10.40.11
    85|cache-02 ansible_host=10.10.40.12
    86|cache-03 ansible_host=10.10.40.13
    87|
    88|[k8s:children]
    89|k8s_masters
    90|k8s_workers
    91|
    92|[k8s_masters]
    93|k8s-master-01 ansible_host=10.10.10.11
    94|k8s-master-02 ansible_host=10.10.10.12
    95|k8s-master-03 ansible_host=10.10.10.13
    96|
    97|[k8s_workers]
    98|k8s-worker-01 ansible_host=10.10.10.21
    99|k8s-worker-02 ansible_host=10.10.10.22
   100|k8s-worker-03 ansible_host=10.10.10.23
   101|```
   102|
   103|### 2.2 基础配置Playbook
   104|
   105|```yaml
   106|# playbooks/base.yml
   107|---
   108|- name: 基础服务器配置
   109|  hosts: all
   110|  become: yes
   111|  vars:
   112|    timezone: "Asia/Shanghai"
   113|    ntp_servers:
   114|      - ntp.aliyun.com
   115|      - ntp1.aliyun.com
   116|  
   117|  tasks:
   118|    - name: 设置时区
   119|      timezone:
   120|        name: "{{ timezone }}"
   121|    
   122|    - name: 配置NTP
   123|      template:
   124|        src: chrony.conf.j2
   125|        dest: /etc/chrony.conf
   126|      notify: restart chrony
   127|    
   128|    - name: 关闭SELinux
   129|      selinux:
   130|        state: disabled
   131|    
   132|    - name: 关闭防火墙
   133|      systemd:
   134|        name: firewalld
   135|        state: stopped
   136|        enabled: no
   137|    
   138|    - name: 加载内核模块
   139|      modprobe:
   140|        name: "{{ item }}"
   141|        state: present
   142|      loop:
   143|        - overlay
   144|        - br_netfilter
   145|    
   146|    - name: 配置内核参数
   147|      sysctl:
   148|        name: "{{ item.name }}"
   149|        value: "{{ item.value }}"
   150|        sysctl_set: yes
   151|        reload: yes
   152|      loop:
   153|        - { name: 'net.bridge.bridge-nf-call-iptables', value: '1' }
   154|        - { name: 'net.ipv4.ip_forward', value: '1' }
   155|        - { name: 'vm.swappiness', value: '0' }
   156|        - { name: 'net.core.somaxconn', value: '65535' }
   157|    
   158|    - name: 安装常用工具
   159|      yum:
   160|        name:
   161|          - vim
   162|          - htop
   163|          - iotop
   164|          - net-tools
   165|          - lsof
   166|          - strace
   167|          - tcpdump
   168|          - curl
   169|          - wget
   170|          - git
   171|          - jq
   172|          - tree
   173|          - tmux
   174|        state: present
   175|    
   176|    - name: 配置系统限制
   177|      template:
   178|        src: limits.conf.j2
   179|        dest: /etc/security/limits.conf
   180|    
   181|    - name: 配置SSH安全
   182|      lineinfile:
   183|        path: /etc/ssh/sshd_config
   184|        regexp: "{{ item.regexp }}"
   185|        line: "{{ item.line }}"
   186|      loop:
   187|        - { regexp: '^#?PermitRootLogin', line: 'PermitRootLogin prohibit-password' }
   188|        - { regexp: '^#?PasswordAuthentication', line: 'PasswordAuthentication no' }
   189|        - { regexp: '^#?MaxAuthTries', line: 'MaxAuthTries 3' }
   190|        - { regexp: '^#?ClientAliveInterval', line: 'ClientAliveInterval 300' }
   191|      notify: restart sshd
   192|    
   193|    - name: 配置Ansible用户
   194|      user:
   195|        name: deploy
   196|        groups: wheel
   197|        shell: /bin/bash
   198|        create_home: yes
   199|    
   200|    - name: 部署SSH公钥
   201|      authorized_key:
   202|        user: deploy
   203|        key: "{{ lookup('file', '~/.ssh/id_rsa.pub') }}"
   204|  
   205|  handlers:
   206|    - name: restart chrony
   207|      systemd: name=chronyd state=restarted
   208|    
   209|    - name: restart sshd
   210|      systemd: name=sshd state=restarted
   211|```
   212|
   213|### 2.3 Docker部署Playbook
   214|
   215|```yaml
   216|# roles/docker/tasks/main.yml
   217|---
   218|- name: 安装Docker依赖
   219|  yum:
   220|    name:
   221|      - yum-utils
   222|      - device-mapper-persistent-data
   223|      - lvm2
   224|    state: present
   225|
   226|- name: 添加Docker仓库
   227|  yum_repository:
   228|    name: docker-ce
   229|    description: Docker CE Repository
   230|    baseurl: https://download.docker.com/linux/centos/$releasever/$basearch/stable
   231|    gpgcheck: yes
   232|    gpgkey: https://download.docker.com/linux/centos/gpg
   233|
   234|- name: 安装Docker
   235|  yum:
   236|    name:
   237|      - docker-ce
   238|      - docker-ce-cli
   239|      - containerd.io
   240|      - docker-compose-plugin
   241|    state: present
   242|
   243|- name: 配置Docker daemon
   244|  template:
   245|    src: daemon.json.j2
   246|    dest: /etc/docker/daemon.json
   247|
   248|- name: 启动Docker
   249|  systemd:
   250|    name: docker
   251|    state: started
   252|    enabled: yes
   253|```
   254|
   255|```json
   256|// roles/docker/templates/daemon.json.j2
   257|{
   258|  "data-root": "/data/docker",
   259|  "storage-driver": "overlay2",
   260|  "log-driver": "json-file",
   261|  "log-opts": {
   262|    "max-size": "100m",
   263|    "max-file": "3"
   264|  },
   265|  "registry-mirrors": [
   266|    "https://mirror.ccs.tencentyun.com"
   267|  ],
   268|  "insecure-registries": [
   269|    "harbor.internal.com"
   270|  ],
   271|  "max-concurrent-downloads": 10,
   272|  "max-concurrent-uploads": 5,
   273|  "default-ulimits": {
   274|    "nofile": {
   275|      "Name": "nofile",
   276|      "Hard": 65535,
   277|      "Soft": 65535
   278|    }
   279|  }
   280|}
   281|```
   282|
   283|---
   284|
   285|## 三、Terraform基础设施
   286|
   287|### 3.1 阿里云ECS集群
   288|
   289|```hcl
   290|# main.tf - 阿里云ECS集群
   291|terraform {
   292|  required_providers {
   293|    alicloud = {
   294|      source  = "aliyun/alicloud"
   295|      version = "~> 1.200"
   296|    }
   297|  }
   298|  backend "oss" {
   299|    bucket = "terraform-state-prod"
   300|    key    = "k8s-cluster/terraform.tfstate"
   301|    region = "cn-hangzhou"
   302|  }
   303|}
   304|
   305|provider "alicloud" {
   306|  region = var.region
   307|}
   308|
   309|# VPC
   310|resource "alicloud_vpc" "main" {
   311|  vpc_name   = "production-vpc"
   312|  cidr_block = "10.0.0.0/16"
   313|}
   314|
   315|# 可用区
   316|data "alicloud_zones" "available" {
   317|  available_resource_creation = "VSwitch"
   318|}
   319|
   320|# 交换机
   321|resource "alicloud_vswitch" "web" {
   322|  count        = 3
   323|  vpc_id       = alicloud_vpc.main.id
   324|  cidr_block   = "10.0.${count.index + 1}.0/24"
   325|  zone_id      = data.alicloud_zones.available.zones[count.index % 3].id
   326|  vswitch_name = "web-subnet-${count.index + 1}"
   327|}
   328|
   329|# 安全组
   330|resource "alicloud_security_group" "k8s" {
   331|  name   = "k8s-sg"
   332|  vpc_id = alicloud_vpc.main.id
   333|}
   334|
   335|resource "alicloud_security_group_rule" "allow_http" {
   336|  type              = "ingress"
   337|  ip_protocol       = "tcp"
   338|  nic_type          = "intranet"
   339|  policy            = "accept"
   340|  port_range        = "80/80"
   341|  security_group_id = alicloud_security_group.k8s.id
   342|  cidr_ip           = "0.0.0.0/0"
   343|}
   344|
   345|resource "alicloud_security_group_rule" "allow_https" {
   346|  type              = "ingress"
   347|  ip_protocol       = "tcp"
   348|  nic_type          = "intranet"
   349|  policy            = "accept"
   350|  port_range        = "443/443"
   351|  security_group_id = alicloud_security_group.k8s.id
   352|  cidr_ip           = "0.0.0.0/0"
   353|}
   354|
   355|# K8s Master节点
   356|resource "alicloud_instance" "k8s_master" {
   357|  count                = 3
   358|  instance_name        = "k8s-master-${count.index + 1}"
   359|  host_name            = "k8s-master-${count.index + 1}"
   360|  instance_type        = "ecs.g7.2xlarge"  # 8C/32G
   361|  image_id             = "centos_7_9_x64_20G_alibase_20230816.vhd"
   362|  security_groups      = [alicloud_security_group.k8s.id]
   363|  vswitch_id           = alicloud_vswitch.web[count.index % 3].id
   364|  system_disk_category = "cloud_essd"
   365|  system_disk_size     = 100
   366|  system_disk_performance_level = "PL1"
   367|  key_name             = alicloud_key_pair.deploy.key_name
   368|  
   369|  tags = {
   370|    Role     = "k8s-master"
   371|    Cluster  = "production"
   372|  }
   373|}
   374|
   375|# K8s Worker节点
   376|resource "alicloud_instance" "k8s_worker" {
   377|  count                = 5
   378|  instance_name        = "k8s-worker-${count.index + 1}"
   379|  host_name            = "k8s-worker-${count.index + 1}"
   380|  instance_type        = count.index < 3 ? "ecs.c7.4xlarge" : "ecs.g7.8xlarge"
   381|  image_id             = "centos_7_9_x64_20G_alibase_20230816.vhd"
   382|  security_groups      = [alicloud_security_group.k8s.id]
   383|  vswitch_id           = alicloud_vswitch.web[count.index % 3].id
   384|  system_disk_category = "cloud_essd"
   385|  system_disk_size     = 100
   386|  key_name             = alicloud_key_pair.deploy.key_name
   387|  
   388|  tags = {
   389|    Role     = "k8s-worker"
   390|    Cluster  = "production"
   391|  }
   392|}
   393|
   394|# RDS MySQL
   395|resource "alicloud_db_instance" "mysql" {
   396|  engine               = "MySQL"
   397|  engine_version       = "8.0"
   398|  instance_type        = "rds.mysql.s3.large"  # 8C/32G
   399|  instance_storage     = 500
   400|  instance_charge_type = "Postpaid"
   401|  instance_name        = "production-mysql"
   402|  vswitch_id           = alicloud_vswitch.web[0].id
   403|  security_ips         = ["10.0.0.0/16"]
   404|  
   405|  db_instance_storage_type = "cloud_essd"
   406|  db_instance_disk_category = "cloud_essd"
   407|  
   408|  tags = {
   409|    Role = "database"
   410|  }
   411|}
   412|
   413|# Redis
   414|resource "alicloud_kvstore_instance" "redis" {
   415|  db_instance_name = "production-redis"
   416|  instance_class   = "redis.master.small.default"
   417|  instance_type    = "Redis"
   418|  engine_version   = "7.0"
   419|  vswitch_id       = alicloud_vswitch.web[0].id
   420|  security_ips     = ["10.0.0.0/16"]
   421|  
   422|  tags = {
   423|    Role = "cache"
   424|  }
   425|}
   426|```
   427|
   428|### 3.2 变量和输出
   429|
   430|```hcl
   431|# variables.tf
   432|variable "region" {
   433|  description = "阿里云区域"
   434|  default     = "cn-hangzhou"
   435|}
   436|
   437|variable "environment" {
   438|  description = "环境"
   439|  default     = "production"
   440|}
   441|
   442|# outputs.tf
   443|output "vpc_id" {
   444|  value = alicloud_vpc.main.id
   445|}
   446|
   447|output "master_ips" {
   448|  value = alicloud_instance.k8s_master[*].private_ip
   449|}
   450|
   451|output "worker_ips" {
   452|  value = alicloud_instance.k8s_worker[*].private_ip
   453|}
   454|
   455|output "rds_endpoint" {
   456|  value = alicloud_db_instance.mysql.connection_string
   457|}
   458|
   459|output "redis_endpoint" {
   460|  value = alicloud_kvstore_instance.redis.connection_domain
   461|}
   462|```
   463|
   464|---
   465|
   466|## 四、Makefile自动化
   467|
   468|```makefile
   469|# Makefile
   470|.PHONY: help init plan apply destroy
   471|
   472|help:
   473|	@echo "用法:"
   474|	@echo "  make init          初始化Terraform"
   475|	@echo "  make plan          预览变更"
   476|	@echo "  make apply         应用变更"
   477|	@echo "  make destroy       销毁资源"
   478|	@echo "  make ansible-base  运行基础配置"
   479|	@echo "  make ansible-docker 部署Docker"
   480|
   481|init:
   482|	cd terraform && terraform init
   483|
   484|plan:
   485|	cd terraform && terraform plan
   486|
   487|apply:
   488|	cd terraform && terraform apply -auto-approve
   489|
   490|destroy:
   491|	cd terraform && terraform destroy -auto-approve
   492|
   493|ansible-base:
   494|	cd ansible && ansible-playbook -i inventory/production/hosts playbooks/base.yml
   495|
   496|ansible-docker:
   497|	cd ansible && ansible-playbook -i inventory/production/hosts playbooks/docker.yml
   498|
   499|ansible-all:
   500|	cd ansible && ansible-playbook -i inventory/production/hosts playbooks/site.yml
   501|

---

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

> 本项目基于25个语雀知识库(2699篇,584万字)深度学习编写
