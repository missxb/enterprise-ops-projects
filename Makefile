.PHONY: lint test check help

help:  ## 显示帮助
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-15s\033[0m %s\n", $$1, $$2}'

lint:  ## Markdown语法检查
	@python3 tests/lint.py

test:  ## 部署验证测试
	@bash tests/validate.sh

check: lint test  ## 完整检查(lint + test)

deploy-init:  ## 部署: 节点初始化
	@bash scripts/01-k8s/node-init.sh

deploy-k8s:  ## 部署: K8s集群(kubeadm init + join)
	@echo "请按文档01步骤手动执行kubeadm init和join"

deploy-harbor:  ## 部署: Harbor镜像仓库
	@bash scripts/01-k8s/harbor-deploy.sh

deploy-monitor:  ## 部署: 监控系统
	@bash scripts/03-monitor/monitor-deploy.sh

deploy-elk:  ## 部署: ELK日志系统
	@bash scripts/04-elk/elk-deploy.sh

deploy-mysql:  ## 部署: MySQL MGR集群
	@bash scripts/05-mysql/mysql-cluster-deploy.sh

deploy-redis:  ## 部署: Redis Cluster
	@bash scripts/06-redis/redis-cluster-deploy.sh

deploy-nginx:  ## 部署: Nginx+Keepalived HA
	@bash scripts/07-nginx/nginx-ha-deploy.sh

deploy-gateway:  ## 部署: K8s网关(Istio+Kong)
	@bash scripts/09-gateway/gateway-deploy.sh

deploy-security:  ## 部署: 安全加固
	@bash scripts/10-security/security-harden.sh

deploy-cicd:  ## 部署: CI/CD(Jenkins+SonarQube+ArgoCD)
	@bash scripts/02-cicd/cicd-deploy.sh

deploy-all: deploy-init deploy-harbor deploy-cicd deploy-monitor deploy-elk deploy-mysql deploy-redis deploy-nginx deploy-gateway deploy-security  ## 部署: 全部组件
