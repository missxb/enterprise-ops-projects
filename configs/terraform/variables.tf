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
}
