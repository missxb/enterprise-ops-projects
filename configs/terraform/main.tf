terraform {
  required_version = ">= 1.0"
  required_providers {
    alicloud = {
      source  = "aliyun/alicloud"
      version = "~> 2.0"
    }
  }
}

provider "alicloud" {
  region = var.region
}

resource "alicloud_vpc" "main" {
  vpc_name   = "${var.project}-vpc"
  cidr_block = "10.10.0.0/16"
}

resource "alicloud_security_group" "main" {
  name   = "${var.project}-sg"
  vpc_id = alicloud_vpc.main.id
}

resource "alicloud_security_group_rule" "allow_ssh" {
  security_group_id = alicloud_security_group.main.id
  type              = "ingress"
  ip_protocol       = "tcp"
  port_range        = "22/22"
  cidr_ip           = "0.0.0.0/0"
}
