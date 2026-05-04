# CHANGELOG

## [1.3.0] - 2026-05-04

### Added
- 3个检查脚本: elk-check/monitor-check/security-check
- 06-Redis: MariaDB兼容说明
- scripts/02-cicd: CI/CD完整部署(Jenkins+SonarQube+ArgoCD)
- scripts/08-ansible: Ansible批量部署
- scripts/09-gateway: 网关完整部署(Kong+Istio+Jaeger)
- 等保合规检查脚本
- Prometheus告警规则文件
- Filebeat日志采集配置

### Fixed
- 06: Redis互斥→"不混合使用"+二选一说明
- 06: LASTSAVE竞态→BEFORE比较+300s超时
- 06: cluster-node-timeout拼写
- 07: ip_hash注释移除错误说明
- 01: MetalLB v1beta1→v1beta2
- README: Redis 7.0→7.2
- compliance: SSH密钥改warn+防火墙改warn
- nginx后端IP对齐IPAM(10.10.50.x)
- Kaniko: --context/--cache/--snapshotMode
- Terraform: Worker count 5+oss backend
- .env.example: +KEEPALIVED/ES/SMTP变量

## [1.2.0] - 2026-05-04

### Added
- tests/lint.py: Python Markdown检查器
- tests/validate.sh v4: 34项自动化验证
- Makefile: make lint/test/check
- .env.example: 环境变量模板

### Fixed
- Helm deployment.yaml: resources/Probe/securityContext结构修复
- Helm: 添加configmap.yaml+secret.yaml模板
- 06: Redis互斥说明修正
- 06: cluster-node-timeout拼写修正
- Terraform: SSH限制为admin_cidr
- Harbor: 版本统一2.12.0
- 05: MySQL PITR密码不暴露命令行
- 06: Redis备份IP改为变量

## [1.1.0] - 2026-05-03

### Added
- scripts/: 10个可执行脚本
- configs/: .gitlab-ci.yml/Dockerfile/Helm/Ansible/Terraform
- tests/: validate.sh
- .gitignore: 完善忽略规则

### Fixed
- ES端口9092→9200
- Keepalived密码明文→占位符
- Redis LASTSAVE逻辑
- MySQL binlog_checksum=CRC32
- GitLab CI only→rules
- Docker daemon.json格式
- Prometheus Helm路径

## [1.0.0] - 2026-05-02

### Added
- 10个企业级运维项目文档
- 版本兼容性矩阵
- 踩坑记录章节
- IPAM规划文档
