# 企业级项目06: Terraform 云基础设施即代码 (IaC)

## 📋 项目概述

使用Terraform管理AWS云基础设施，包含VPC、EKS、RDS、Redis、ALB等完整企业级架构。

**云平台**: AWS | **IaC**: Terraform | **状态管理**: S3 + DynamoDB

---

## 🏗️ 架构图

```
┌─────────────────────────────────────────────────────────────────┐
│                    AWS 云基础设施架构                              │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │  Region: ap-southeast-1 (新加坡)                          │   │
│  │                                                          │   │
│  │  ┌────────────────────────────────────────────────────┐  │   │
│  │  │  VPC: 10.0.0.0/16                                  │  │   │
│  │  │                                                    │  │   │
│  │  │  ┌─────────────┐  ┌─────────────┐                 │  │   │
│  │  │  │ Public Sub  │  │ Public Sub  │                 │  │   │
│  │  │  │ 10.0.1.0/24 │  │ 10.0.2.0/24 │                 │  │   │
│  │  │  │ (AZ-a)      │  │ (AZ-b)      │                 │  │   │
│  │  │  │ NAT Gateway │  │ ALB         │                 │  │   │
│  │  │  └─────────────┘  └─────────────┘                 │  │   │
│  │  │                                                    │  │   │
│  │  │  ┌─────────────┐  ┌─────────────┐                 │  │   │
│  │  │  │ Private Sub │  │ Private Sub │                 │  │   │
│  │  │  │ 10.0.10.0/24│  │ 10.0.20.0/24│                 │  │   │
│  │  │  │ EKS Nodes   │  │ RDS/Redis   │                 │  │   │
│  │  │  │ (AZ-a)      │  │ (AZ-b)      │                 │  │   │
│  │  │  └─────────────┘  └─────────────┘                 │  │   │
│  │  └────────────────────────────────────────────────────┘  │   │
│  │                                                          │   │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐     │   │
│  │  │   EKS       │  │   RDS       │  │  ElastiCache│     │   │
│  │  │  Cluster    │  │  MySQL 8.0  │  │  Redis 7    │     │   │
│  │  │  3 Nodes    │  │  Multi-AZ   │  │  Cluster    │     │   │
│  │  └─────────────┘  └─────────────┘  └─────────────┘     │   │
│  │                                                          │   │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐     │   │
│  │  │  S3 Bucket  │  │ CloudWatch  │  │ Route53     │     │   │
│  │  │  (静态资源)  │  │  (监控)     │  │  (DNS)      │     │   │
│  │  └─────────────┘  └─────────────┘  └─────────────┘     │   │
│  └──────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

---

## 📁 项目文件结构

```
terraform-aws-infra/
├── main.tf                  # 主配置
├── variables.tf             # 变量定义
├── outputs.tf               # 输出值
├── providers.tf             # Provider配置
├── backend.tf               # 状态管理
├── modules/
│   ├── vpc/
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   └── outputs.tf
│   ├── eks/
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   └── outputs.tf
│   ├── rds/
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   └── outputs.tf
│   ├── redis/
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   └── outputs.tf
│   └── alb/
│       ├── main.tf
│       ├── variables.tf
│       └── outputs.tf
├── environments/
│   ├── production/
│   │   ├── terraform.tfvars
│   │   └── backend.tf
│   └── staging/
│       ├── terraform.tfvars
│       └── backend.tf
├── scripts/
│   ├── init.sh              # 初始化脚本
│   ├── deploy.sh            # 部署脚本
│   └── destroy.sh           # 销毁脚本
└── README.md
```

---

## 🚀 核心配置文件

### providers.tf

```hcl
# ============================================
# Terraform Provider配置
# ============================================

terraform {
  required_version = ">= 1.5.0"
  
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.23"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.11"
    }
  }
}

provider "aws" {
  region = var.aws_region
  
  default_tags {
    tags = {
      Environment = var.environment
      Project     = var.project_name
      ManagedBy   = "Terraform"
      Owner       = var.owner
    }
  }
}

# Kubernetes Provider (配置EKS集群后使用)
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_ca_certificate)
  
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
  }
}

# Helm Provider
provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_ca_certificate)
    
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
    }
  }
}
```

### backend.tf

```hcl
# ============================================
# 远程状态管理 (S3 + DynamoDB)
# ============================================

terraform {
  backend "s3" {
    bucket         = "company-terraform-state"
    key            = "production/terraform.tfstate"
    region         = "ap-southeast-1"
    encrypt        = true
    dynamodb_table = "terraform-lock"
  }
}
```

### variables.tf

```hcl
# ============================================
# 变量定义
# ============================================

variable "aws_region" {
  description = "AWS区域"
  type        = string
  default     = "ap-southeast-1"
}

variable "environment" {
  description = "环境名称"
  type        = string
  default     = "production"
}

variable "project_name" {
  description = "项目名称"
  type        = string
  default     = "enterprise-app"
}

variable "owner" {
  description = "所有者"
  type        = string
  default     = "ops-team"
}

# ===== VPC配置 =====
variable "vpc_cidr" {
  description = "VPC CIDR块"
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "可用区列表"
  type        = list(string)
  default     = ["ap-southeast-1a", "ap-southeast-1b"]
}

# ===== EKS配置 =====
variable "eks_cluster_name" {
  description = "EKS集群名称"
  type        = string
  default     = "enterprise-eks"
}

variable "eks_cluster_version" {
  description = "Kubernetes版本"
  type        = string
  default     = "1.29"
}

variable "eks_node_instance_types" {
  description = "节点实例类型"
  type        = list(string)
  default     = ["t3.large"]
}

variable "eks_node_desired_size" {
  description = "期望节点数"
  type        = number
  default     = 3
}

variable "eks_node_min_size" {
  description = "最小节点数"
  type        = number
  default     = 2
}

variable "eks_node_max_size" {
  description = "最大节点数"
  type        = number
  default     = 10
}

# ===== RDS配置 =====
variable "rds_instance_class" {
  description = "RDS实例类型"
  type        = string
  default     = "db.r6g.large"
}

variable "rds_engine_version" {
  description = "MySQL版本"
  type        = string
  default     = "8.0"
}

variable "rds_allocated_storage" {
  description = "存储空间(GB)"
  type        = number
  default     = 100
}

variable "rds_max_allocated_storage" {
  description = "最大存储空间(GB)"
  type        = number
  default     = 500
}

variable "rds_master_username" {
  description = "数据库管理员用户名"
  type        = string
  default     = "admin"
  sensitive   = true
}

variable "rds_master_password" {
  description = "数据库管理员密码"
  type        = string
  sensitive   = true
}

# ===== Redis配置 =====
variable "redis_node_type" {
  description = "Redis节点类型"
  type        = string
  default     = "cache.r6g.large"
}

variable "redis_engine_version" {
  description = "Redis版本"
  type        = string
  default     = "7.0"
}

variable "redis_num_cache_nodes" {
  description = "Redis节点数"
  type        = number
  default     = 2
}

# ===== 域名配置 =====
variable "domain_name" {
  description = "域名"
  type        = string
  default     = "app.company.com"
}

variable "certificate_arn" {
  description = "SSL证书ARN"
  type        = string
}
```

### main.tf

```hcl
# ============================================
# 主配置 - 调用模块
# ============================================

# ===== S3状态存储 =====
resource "aws_s3_bucket" "terraform_state" {
  bucket = "company-terraform-state"
  
  lifecycle {
    prevent_destroy = true
  }
  
  tags = {
    Name        = "Terraform State Bucket"
    Description = "Terraform远程状态存储"
  }
}

resource "aws_s3_bucket_versioning" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id
  
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id
  
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id
  
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ===== DynamoDB锁表 =====
resource "aws_dynamodb_table" "terraform_lock" {
  name         = "terraform-lock"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"
  
  attribute {
    name = "LockID"
    type = "S"
  }
  
  tags = {
    Name = "Terraform Lock Table"
  }
}

# ===== VPC模块 =====
module "vpc" {
  source = "./modules/vpc"
  
  vpc_cidr           = var.vpc_cidr
  availability_zones = var.availability_zones
  environment        = var.environment
  project_name       = var.project_name
}

# ===== EKS模块 =====
module "eks" {
  source = "./modules/eks"
  
  cluster_name       = var.eks_cluster_name
  cluster_version    = var.eks_cluster_version
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids
  
  node_instance_types = var.eks_node_instance_types
  node_desired_size   = var.eks_node_desired_size
  node_min_size       = var.eks_node_min_size
  node_max_size       = var.eks_node_max_size
  
  environment  = var.environment
  project_name = var.project_name
}

# ===== RDS模块 =====
module "rds" {
  source = "./modules/rds"
  
  instance_class    = var.rds_instance_class
  engine_version    = var.rds_engine_version
  allocated_storage = var.rds_allocated_storage
  max_allocated_storage = var.rds_max_allocated_storage
  
  master_username = var.rds_master_username
  master_password = var.rds_master_password
  
  vpc_id             = module.vpc.vpc_id
  subnet_ids         = module.vpc.private_subnet_ids
  
  allowed_security_groups = [module.eks.node_security_group_id]
  
  environment  = var.environment
  project_name = var.project_name
}

# ===== Redis模块 =====
module "redis" {
  source = "./modules/redis"
  
  node_type        = var.redis_node_type
  engine_version   = var.redis_engine_version
  num_cache_nodes  = var.redis_num_cache_nodes
  
  vpc_id             = module.vpc.vpc_id
  subnet_ids         = module.vpc.private_subnet_ids
  
  allowed_security_groups = [module.eks.node_security_group_id]
  
  environment  = var.environment
  project_name = var.project_name
}

# ===== ALB模块 =====
module "alb" {
  source = "./modules/alb"
  
  vpc_id             = module.vpc.vpc_id
  public_subnet_ids  = module.vpc.public_subnet_ids
  
  certificate_arn = var.certificate_arn
  domain_name     = var.domain_name
  
  environment  = var.environment
  project_name = var.project_name
}

# ===== Route53 =====
resource "aws_route53_record" "app" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = var.domain_name
  type    = "A"
  
  alias {
    name                   = module.alb.dns_name
    zone_id                = module.alb.zone_id
    evaluate_target_health = true
  }
}

data "aws_route53_zone" "main" {
  name         = "company.com"
  private_zone = false
}
```

### modules/vpc/main.tf

```hcl
# ============================================
# VPC模块
# ============================================

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
  
  tags = {
    Name = "${var.project_name}-vpc"
  }
}

# ===== Internet Gateway =====
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  
  tags = {
    Name = "${var.project_name}-igw"
  }
}

# ===== NAT Gateway =====
resource "aws_eip" "nat" {
  count  = length(var.availability_zones)
  domain = "vpc"
  
  tags = {
    Name = "${var.project_name}-nat-eip-${count.index}"
  }
}

resource "aws_nat_gateway" "main" {
  count         = length(var.availability_zones)
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id
  
  tags = {
    Name = "${var.project_name}-nat-${count.index}"
  }
  
  depends_on = [aws_internet_gateway.main]
}

# ===== Public Subnets =====
resource "aws_subnet" "public" {
  count             = length(var.availability_zones)
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index + 1)
  availability_zone = var.availability_zones[count.index]
  
  map_public_ip_on_launch = true
  
  tags = {
    Name                                           = "${var.project_name}-public-${var.availability_zones[count.index]}"
    "kubernetes.io/role/elb"                        = "1"
    "kubernetes.io/cluster/${var.project_name}-eks"  = "shared"
  }
}

# ===== Private Subnets =====
resource "aws_subnet" "private" {
  count             = length(var.availability_zones)
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index + 10)
  availability_zone = var.availability_zones[count.index]
  
  tags = {
    Name                                           = "${var.project_name}-private-${var.availability_zones[count.index]}"
    "kubernetes.io/role/internal-elb"               = "1"
    "kubernetes.io/cluster/${var.project_name}-eks"  = "shared"
  }
}

# ===== Route Tables =====
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  
  tags = {
    Name = "${var.project_name}-public-rt"
  }
}

resource "aws_route_table_association" "public" {
  count          = length(var.availability_zones)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  count  = length(var.availability_zones)
  vpc_id = aws_vpc.main.id
  
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main[count.index].id
  }
  
  tags = {
    Name = "${var.project_name}-private-rt-${count.index}"
  }
}

resource "aws_route_table_association" "private" {
  count          = length(var.availability_zones)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# ===== VPC Flow Logs =====
resource "aws_flow_log" "main" {
  iam_role_arn    = aws_iam_role.flow_log.arn
  log_destination = aws_cloudwatch_log_group.flow_log.arn
  traffic_type    = "ALL"
  vpc_id          = aws_vpc.main.id
  
  tags = {
    Name = "${var.project_name}-flow-log"
  }
}

resource "aws_cloudwatch_log_group" "flow_log" {
  name              = "/aws/vpc/flow-log/${var.project_name}"
  retention_in_days = 30
}

resource "aws_iam_role" "flow_log" {
  name = "${var.project_name}-flow-log-role"
  
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "vpc-flow-logs.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy" "flow_log" {
  name = "${var.project_name}-flow-log-policy"
  role = aws_iam_role.flow_log.id
  
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams"
      ]
      Effect   = "Allow"
      Resource = "*"
    }]
  })
}
```

### modules/eks/main.tf

```hcl
# ============================================
# EKS模块
# ============================================

# ===== EKS集群 =====
resource "aws_eks_cluster" "main" {
  name     = var.cluster_name
  version  = var.cluster_version
  role_arn = aws_iam_role.eks_cluster.arn
  
  vpc_config {
    subnet_ids              = var.private_subnet_ids
    endpoint_private_access = true
    endpoint_public_access  = true
    security_group_ids      = [aws_security_group.eks_cluster.id]
  }
  
  enabled_cluster_log_types = [
    "api",
    "audit",
    "authenticator",
    "controllerManager",
    "scheduler"
  ]
  
  tags = {
    Name = var.cluster_name
  }
  
  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_policy,
    aws_iam_role_policy_attachment.eks_vpc_resource_controller
  ]
}

# ===== 节点组 =====
resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${var.cluster_name}-nodes"
  node_role_arn   = aws_iam_role.eks_nodes.arn
  subnet_ids      = var.private_subnet_ids
  
  instance_types = var.node_instance_types
  
  scaling_config {
    desired_size = var.node_desired_size
    min_size     = var.node_min_size
    max_size     = var.node_max_size
  }
  
  update_config {
    max_unavailable = 1
  }
  
  labels = {
    role = "general"
  }
  
  tags = {
    Name = "${var.cluster_name}-nodes"
  }
  
  depends_on = [
    aws_iam_role_policy_attachment.eks_worker_node_policy,
    aws_iam_role_policy_attachment.eks_cni_policy,
    aws_iam_role_policy_attachment.eks_ec2_container_registry
  ]
}

# ===== 安全组 =====
resource "aws_security_group" "eks_cluster" {
  name_prefix = "${var.cluster_name}-cluster-"
  vpc_id      = var.vpc_id
  
  ingress {
    from_port = 443
    to_port   = 443
    protocol  = "tcp"
    self      = true
  }
  
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  tags = {
    Name = "${var.cluster_name}-cluster-sg"
  }
}

# ===== IAM角色 =====
resource "aws_iam_role" "eks_cluster" {
  name = "${var.cluster_name}-cluster-role"
  
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "eks.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.eks_cluster.name
}

resource "aws_iam_role_policy_attachment" "eks_vpc_resource_controller" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSVPCResourceController"
  role       = aws_iam_role.eks_cluster.name
}

resource "aws_iam_role" "eks_nodes" {
  name = "${var.cluster_name}-node-role"
  
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_worker_node_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.eks_nodes.name
}

resource "aws_iam_role_policy_attachment" "eks_cni_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.eks_nodes.name
}

resource "aws_iam_role_policy_attachment" "eks_ec2_container_registry" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.eks_nodes.name
}
```

### modules/rds/main.tf

```hcl
# ============================================
# RDS模块 (Multi-AZ MySQL)
# ============================================

# ===== 子网组 =====
resource "aws_db_subnet_group" "main" {
  name       = "${var.project_name}-db-subnet"
  subnet_ids = var.subnet_ids
  
  tags = {
    Name = "${var.project_name}-db-subnet-group"
  }
}

# ===== 参数组 =====
resource "aws_db_parameter_group" "main" {
  name   = "${var.project_name}-mysql-params"
  family = "mysql8.0"
  
  parameter {
    name  = "character_set_server"
    value = "utf8mb4"
  }
  
  parameter {
    name  = "collation_server"
    value = "utf8mb4_unicode_ci"
  }
  
  parameter {
    name  = "innodb_buffer_pool_size"
    value = "{DBInstanceClassMemory*3/4}"
  }
  
  parameter {
    name  = "max_connections"
    value = "500"
  }
  
  parameter {
    name  = "slow_query_log"
    value = "1"
  }
  
  parameter {
    name  = "long_query_time"
    value = "2"
  }
  
  parameter {
    name  = "general_log"
    value = "0"
  }
}

# ===== RDS实例 =====
resource "aws_db_instance" "main" {
  identifier = "${var.project_name}-mysql"
  
  engine               = "mysql"
  engine_version       = var.engine_version
  instance_class       = var.instance_class
  
  allocated_storage     = var.allocated_storage
  max_allocated_storage = var.max_allocated_storage
  storage_type          = "gp3"
  storage_encrypted     = true
  
  db_name  = "enterprise_app"
  username = var.master_username
  password = var.master_password
  
  multi_az               = true
  db_subnet_group_name   = aws_db_subnet_group.main.name
  parameter_group_name   = aws_db_parameter_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  
  backup_retention_period = 7
  backup_window          = "03:00-04:00"
  maintenance_window     = "Mon:04:00-Mon:05:00"
  
  auto_minor_version_upgrade = true
  copy_tags_to_snapshot      = true
  deletion_protection        = true
  skip_final_snapshot       = false
  final_snapshot_identifier = "${var.project_name}-mysql-final"
  
  performance_insights_enabled          = true
  performance_insights_retention_period = 7
  
  enabled_cloudwatch_logs_exports = ["audit", "error", "general", "slowquery"]
  
  tags = {
    Name = "${var.project_name}-mysql"
  }
}

# ===== 安全组 =====
resource "aws_security_group" "rds" {
  name_prefix = "${var.project_name}-rds-"
  vpc_id      = var.vpc_id
  
  ingress {
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = var.allowed_security_groups
  }
  
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  tags = {
    Name = "${var.project_name}-rds-sg"
  }
}
```

### modules/redis/main.tf

```hcl
# ============================================
# ElastiCache Redis模块
# ============================================

resource "aws_elasticache_subnet_group" "main" {
  name       = "${var.project_name}-redis-subnet"
  subnet_ids = var.subnet_ids
}

resource "aws_elasticache_replication_group" "main" {
  replication_group_id = "${var.project_name}-redis"
  description          = "Redis cluster for ${var.project_name}"
  
  engine               = "redis"
  engine_version       = var.engine_version
  node_type            = var.node_type
  num_cache_clusters   = var.num_cache_nodes
  
  port = 6379
  
  automatic_failover_enabled = true
  multi_az_enabled          = true
  
  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
  
  subnet_group_name  = aws_elasticache_subnet_group.main.name
  security_group_ids = [aws_security_group.redis.id]
  
  snapshot_retention_limit = 7
  snapshot_window         = "03:00-05:00"
  maintenance_window      = "sun:05:00-sun:07:00"
  
  auto_minor_version_upgrade = true
  
  tags = {
    Name = "${var.project_name}-redis"
  }
}

resource "aws_security_group" "redis" {
  name_prefix = "${var.project_name}-redis-"
  vpc_id      = var.vpc_id
  
  ingress {
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = var.allowed_security_groups
  }
  
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  tags = {
    Name = "${var.project_name}-redis-sg"
  }
}
```

### outputs.tf

```hcl
# ============================================
# 输出值
# ============================================

output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "eks_cluster_endpoint" {
  description = "EKS集群端点"
  value       = module.eks.cluster_endpoint
}

output "eks_cluster_name" {
  description = "EKS集群名称"
  value       = module.eks.cluster_name
}

output "rds_endpoint" {
  description = "RDS端点"
  value       = module.rds.endpoint
}

output "redis_endpoint" {
  description = "Redis端点"
  value       = module.redis.endpoint
}

output "alb_dns_name" {
  description = "ALB DNS名称"
  value       = module.alb.dns_name
}

output "app_url" {
  description = "应用URL"
  value       = "https://${var.domain_name}"
}
```

### environments/production/terraform.tfvars

```hcl
# ============================================
# 生产环境变量
# ============================================

aws_region   = "ap-southeast-1"
environment  = "production"
project_name = "enterprise-app"
owner        = "ops-team"

# VPC
vpc_cidr           = "10.0.0.0/16"
availability_zones = ["ap-southeast-1a", "ap-southeast-1b"]

# EKS
eks_cluster_name       = "enterprise-eks"
eks_cluster_version    = "1.29"
eks_node_instance_types = ["t3.large"]
eks_node_desired_size   = 3
eks_node_min_size       = 2
eks_node_max_size       = 10

# RDS
rds_instance_class      = "db.r6g.large"
rds_engine_version      = "8.0"
rds_allocated_storage   = 100
rds_max_allocated_storage = 500

# Redis
redis_node_type       = "cache.r6g.large"
redis_engine_version  = "7.0"
redis_num_cache_nodes = 2

# 域名
domain_name      = "app.company.com"
certificate_arn  = "arn:aws:acm:ap-southeast-1:123456789012:certificate/xxx"
```

---

## 🔧 运维手册

### 常用命令

```bash
# 初始化
terraform init

# 预览变更
terraform plan -var-file=environments/production/terraform.tfvars

# 应用变更
terraform apply -var-file=environments/production/terraform.tfvars

# 查看状态
terraform state list
terraform state show module.eks.aws_eks_cluster.main

# 导入已有资源
terraform import aws_s3_bucket.terraform_state company-terraform-state

# 格式化
terraform fmt -recursive

# 验证配置
terraform validate

# 销毁资源（谨慎！）
terraform destroy -var-file=environments/production/terraform.tfvars
```

---

**作者**: 企业级运维项目集
**版本**: 1.0.0
**更新时间**: 2026-05-02
