.PHONY: cluster demo destroy test lint

cluster: ## Create the local kind cluster + ingress-nginx + Argo Rollouts
	bash scripts/setup-cluster.sh

demo: ## Build the app, load it into kind, and run the full canary demo
	bash scripts/demo-canary.sh

destroy: ## Tear down the local kind cluster
	kind delete cluster --name $${CLUSTER_NAME:-canary-demo}

test: ## Run the Python test suite
	pip install --break-system-packages -q -r requirements-dev.txt
	pytest

lint: ## Run ruff + mypy against the app
	ruff check app tests
	mypy app
