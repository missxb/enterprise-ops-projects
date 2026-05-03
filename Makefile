.PHONY: lint test check deploy help

help:  ## 显示帮助
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-15s\033[0m %s\n", $$1, $$2}'

lint:  ## Markdown语法检查
	@python3 tests/lint.py

test:  ## 部署验证测试
	@bash tests/validate.sh

check: lint test  ## 完整检查(lint + test)
