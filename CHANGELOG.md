# CHANGELOG

## [1.4.0] - 2026-05-05

### Fixed
- PITR脚本重写: binlog预生成SQL文件→MySQL启动后SOURCE应用(支持MGR+GTID)
- PITR脚本: 添加GTID冲突处理说明
- Prometheus YAML: Thanos Sidecar拆分为独立代码块
- Prometheus版本: v2.48.0→v2.50.0对齐README
- Prometheus: Helm chart锁定65.1.0版本
- Prometheus: replica标签添加唯一性说明
- MetalLB: API版本v1beta2→v1beta1, IP池10.10.200→10.10.10.200同子网
- SELinux: Doc01 disabled→permissive(与node-init.sh对齐)
- etcd备份路径: /opt/→/data/(与脚本统一)
- Harbor: systemd docker-compose→docker compose(适配2.12)
- Harbor: ExecStop同步修正
- Harbor: 域名硬编码→${HARBOR_DOMAIN}变量
- Harbor: cert-manager自动续期集成
- containerd: 注释已停用镜像站(tuna/daocloud/noohub)
- K8s防火墙: 补10257/10259/4789端口
- K8s防火墙: 10255标注K8s 1.16+已废弃
- K8s: kubeadm API v1beta3→v1beta4
- Ansible: apt_key→get_url+signed-by(Ubuntu 22.04+)
- Ansible: fail2ban ignoreip白名单
- Redis备份: 动态RDB路径(CONFIG GET替代硬编码)
- Redis: sudo环境变量修复+sudoers说明
- Redis: io-threads注释去重
- MySQL: MGR heredoc变量展开修复
- MySQL: MGR数据一致性校验(pt-table-checksum)
- MySQL: binlog-do_db注释柔化
- mysql-backup.sh: xtrabackup安装检查
- MySQL: ProxySQL密码变量文档化
- validate.sh: Helm模板YAML解析跳过
- validate.sh: root123误报修复
- Helm: 新增serviceaccount.yaml
- Helm: 新增networkpolicy.yaml
- Helm: deployment添加PodAntiAffinity+envFrom
- Helm: 添加failureThreshold
- ES: ILM freeze→searchable_snapshot(ES 8.x)
- ES: node.roles环境变量化
- Kafka: ADVERTISED_LISTENERS改用Downward API
- Kafka: resources 1Gi/2Gi→4Gi/8Gi
- Thanos: store地址改为Headless Service FQDN
- Thanos: Grafana端口10902→9090
- AlertManager: SMTP 465+587备选方案文档
- Istio: 移除fault injection(生产风险)
- Kong: DB-less模式注释redis_host
- Kong: KongIngress废弃标注
- 等保合规: 对齐GB/T 22239-2019标准10大类
- Terraform: image_id改为data source动态查询
- NodeDown告警for时间统一3m
- 混沌表格||语法修复
- 混沌工程: 补充Litmus Chaos+ChaosBlade方案

### Added
- demo-app/: Go HTTP服务+Dockerfile(可运行Demo)
- docs/dr-drill-record-template.md: 灾备演练记录模板
- docs/performance-benchmarks.md: MySQL/Redis/K8s性能基准
- docs/gitops-workflow.md: ArgoCD Application+ApplicationSet完整示例
- docs/change-management.md: 金丝雀发布+DDL审核流程
- docs/capacity-planning.md: 自动化容量巡检脚本
- docs/disaster-recovery-sop.md: 跨机房etcd灾备配置
- .env.example: 扩展至158行,覆盖所有变量
- scripts/05-mysql/pitr-restore.sh: 重写(MGR+GTID安全)
- scripts/01-k8s/harbor-deploy.sh: cert-manager集成说明

### Changed
- Prometheus ConfigMap: Thanos Sidecar拆分为独立Deployment
- Keepalived auth_pass: CHANGEME→${KEEPALIVED_AUTH_PASS}环境变量
- containerd镜像源: 已停用站点注释掉
- K8s防火墙: 所有节点均启用(含K8s集群端口)

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
