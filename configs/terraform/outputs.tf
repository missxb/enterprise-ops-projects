output "vpc_id" {
  value = alicloud_vpc.main.id
}

output "security_group_id" {
  value = alicloud_security_group.main.id
}
