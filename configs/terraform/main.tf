terraform {
  required_version = ">= 1.0"
  required_providers {
    alicloud = {
      source  = "aliyun/alicloud"
      version = "~> 2.0"
    }
  }
  backend "oss" {
    bucket = "terraform-state"
    key    = "enterprise-ops.tfstate"
    region = "cn-hangzhou"
    encrypt = true
    # 阿里云OSS支持原生锁，无需tablestore
  }
}

provider "alicloud" {
  region = var.region
}

variable "key_name" {
  description = "SSH密钥对名称"
  type        = string
}

resource "alicloud_vpc" "main" {
  vpc_name   = "${var.project}-vpc"
  cidr_block = "10.10.0.0/12"
}

resource "alicloud_vswitch" "main" {
  vpc_id     = alicloud_vpc.main.id
  cidr_block = "10.10.0.0/16"
  zone_id    = var.zone_id
}

resource "alicloud_security_group" "main" {
  name   = "${var.project}-sg"
  vpc_id = alicloud_vpc.main.id
}

resource "alicloud_security_group_rule" "ssh" {
  security_group_id = alicloud_security_group.main.id
  type              = "ingress"
  ip_protocol       = "tcp"
  port_range        = "22/22"
  cidr_ip           = var.admin_cidr
  description       = "SSH"
}

# 查找最新可用镜像
data "alicloud_images" "default" {
  name_regex  = "^aliyun_3_x64_"
  most_recent = true
  owners      = "system"
}

resource "alicloud_instance" "master" {
  count                = 3
  instance_name        = "${var.project}-master-${count.index + 1}"
  image_id             = data.alicloud_images.default.images[0].id
  instance_type        = "ecs.g7.2xlarge"  # 8C16G, 文档要求8C16G
  key_name             = var.key_name
  security_groups      = [alicloud_security_group.main.id]
  vswitch_id           = alicloud_vswitch.main.id
  system_disk_category = "cloud_essd"
  system_disk_size     = 50
  tags = {
    Role     = "master"
    Project  = var.project
  }
}

resource "alicloud_instance" "worker" {
  count                = 5
  instance_name        = "${var.project}-worker-${count.index + 1}"
  image_id             = data.alicloud_images.default.images[0].id
  instance_type        = "ecs.g7.4xlarge"  # 16C64G, 文档要求16C64G或32C128G
  key_name             = var.key_name
  security_groups      = [alicloud_security_group.main.id]
  vswitch_id           = alicloud_vswitch.main.id
  system_disk_category = "cloud_essd"
  system_disk_size     = 100
  tags = {
    Role     = "worker"
    Project  = var.project
  }
}

resource "alicloud_db_instance" "mysql" {
  engine               = "MySQL"
  engine_version       = "8.0"
  instance_type        = "rds.mysql.s2.large"
  instance_storage     = 100
  instance_charge_type = "Postpaid"
  instance_name        = "${var.project}-mysql"
  vswitch_id           = alicloud_vswitch.main.id
  security_ips         = ["10.10.0.0/12"]
  tags = {
    Project = var.project
  }
}
