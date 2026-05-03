variable "region" {
  description = "阿里云区域"
  type        = string
  default     = "cn-hangzhou"
}

variable "project" {
  description = "项目名称"
  type        = string
}

variable "zone_id" {
  description = "可用区ID"
  type        = string
  default     = "cn-hangzhou-h"
}

variable "admin_cidr" {
  description = "管理IP白名单CIDR"
  type        = string
  default     = "10.10.0.0/16"
}
