resource "alicloud_vpc" "main" {
  vpc_name   = "${var.project}-vpc"
  cidr_block = "10.10.0.0/12"
}

resource "alicloud_vswitch" "main" {
  vpc_id     = alicloud_vpc.main.id
  cidr_block = "10.10.0.0/24"
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

resource "alicloud_instance" "master" {
  count                = 3
  instance_name        = "${var.project}-master-${count.index + 1}"
  image_id             = "aliyun_3_x64_20G_alibase_20240101.vhd"
  instance_type        = "ecs.g6.large"
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
  image_id             = "aliyun_3_x64_20G_alibase_20240101.vhd"
  instance_type        = "ecs.g6.xlarge"
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
