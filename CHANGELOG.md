# CHANGELOG

## [1.1.0] - 2026-05-04

### Added
- scripts/: 10个可执行脚本(含umask/日志/版本锁定)
- configs/.gitlab-ci.yml: Kaniko安全构建
- configs/Dockerfile: 多阶段构建+非root+容器JVM
- configs/helm/: 完整Chart(Service/HPA/PDB/Ingress)
- configs/terraform/: VPC+安全组+ECS+VSwitch+RDS
- configs/ansible/: Docker Role
- tests/validate.sh: 17项部署验证
- .env.example: 环境变量模板
- .gitignore: 完善忽略规则

### Fixed
- node-init.sh: 锁定K8s版本
- mysql-backup.sh: 移除硬编码binlog
- pitr-restore.sh: 密码不暴露命令行
- redis-backup.sh: IP改为变量
- Dockerfile: 添加非root用户和时区
- Helm: 补充Service/HPA/PDB/Ingress模板
- Terraform: 添加ECS实例和RDS资源

## [1.0.0] - 2026-05-03

### Added
- 10个企业级运维项目文档
- 版本兼容性矩阵
- 踩坑记录章节

### Fixed
- ES端口9092→9200
- Redis LASTSAVE逻辑
- MySQL binlog_checksum=CRC32
- GitLab CI only→rules
- Harbor密码占位符

## [0.9.0] - 2026-05-02

### Added
- 初始项目结构
