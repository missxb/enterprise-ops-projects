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

deploy-all: deploy-init deploy-harbor deploy-monitor deploy-elk  ## 部署: 全部组件
