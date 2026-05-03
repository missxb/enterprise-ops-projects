# CHANGELOG

## [1.2.0] - 2026-05-04

### Added
- tests/lint.py: Python Markdown检查器(相对路径)
- tests/validate.sh v4: 34项自动化验证
- Makefile: make lint/test/check
- .env.example: 环境变量模板(22个变量)

### Fixed
- Helm deployment.yaml: resources/Probe/securityContext结构修复
- 脚本路径: 相对路径替代硬编码
- 硬编码密码: Repl@Pass2024/K8sHA2024Secure/NginxHA2024Secure全部替换
- Makefile: 移除未实现的deploy target

## [1.1.0] - 2026-05-04

### Added
- scripts/: 10个可执行脚本(含umask/日志/版本锁定)
- configs/.gitlab-ci.yml: Kaniko安全构建
- configs/Dockerfile: 多阶段构建+非root+容器JVM
- configs/helm/: 完整Chart(Service/HPA/PDB/Ingress)
- configs/terraform/: VPC+安全组+ECS+VSwitch+RDS
- configs/ansible/: Docker Role
- tests/validate.sh: 部署验证测试
- .env.example: 环境变量模板
- .gitignore: 完善忽略规则

### Fixed
- node-init.sh: 锁定K8s版本
- mysql-backup.sh: 移除硬编码binlog
- pitr-restore.sh: 密码不暴露命令行
- redis-backup.sh: IP改为变量

## [1.0.0] - 2026-05-03

### Added
- 10个企业级运维项目文档
- 基础脚本文件(备份/恢复/检查)
- 版本兼容性矩阵
- 踩坑记录章节

## [0.9.0] - 2026-05-02

### Added
- 初始项目结构
- 10个项目文档
