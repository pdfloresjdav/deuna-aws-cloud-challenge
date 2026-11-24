# Deuna! AWS Cloud Challenge - development & validation commands.
# Everything runs inside the Docker tooling container (see Dockerfile /
# docker-compose.yml). The only host dependencies are Docker (with Compose),
# Git and Make.

COMPOSE ?= docker compose
SERVICE := terraform

# Non-interactive command runner (-T disables TTY allocation so it works in CI).
RUN := $(COMPOSE) run --rm -T $(SERVICE) bash -c

# Terraform root configurations that must be validated.
TF_ROOTS := terraform/bootstrap terraform/environments/dev terraform/environments/prod

TFLINT_CONFIG := /workspace/.tflint.hcl
CHECKOV_CONFIG := /workspace/.checkov.yaml

.DEFAULT_GOAL := help

.PHONY: help setup versions shell fmt fmt-check init validate lint security check

help: ## Display available commands
	@echo "Deuna! AWS Cloud Challenge - make targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

setup: ## Build the development image and show tool versions
	$(COMPOSE) build $(SERVICE)
	@$(MAKE) versions

versions: ## Display installed tool versions
	$(RUN) 'set -e; \
		echo "Terraform : $$(terraform version | head -1)"; \
		echo "TFLint    : $$(tflint --version | head -1)"; \
		echo "Checkov   : $$(checkov --version)"; \
		echo "AWS CLI   : $$(aws --version)"; \
		echo "jq        : $$(jq --version)"; \
		echo "Git       : $$(git --version)"'

shell: ## Open an interactive development container
	$(COMPOSE) run --rm $(SERVICE)

fmt: ## Format Terraform files
	$(RUN) 'terraform fmt -recursive terraform'

fmt-check: ## Verify Terraform formatting (no changes)
	$(RUN) 'terraform fmt -check -recursive terraform'

init: ## Initialize Terraform roots without remote backends
	$(RUN) 'set -e; for d in $(TF_ROOTS); do \
		echo ">> init $$d"; \
		terraform -chdir=$$d init -backend=false -input=false; \
	done'

validate: ## Validate Terraform configurations
	$(RUN) 'set -e; for d in $(TF_ROOTS); do \
		echo ">> validate $$d"; \
		terraform -chdir=$$d init -backend=false -input=false >/dev/null; \
		terraform -chdir=$$d validate; \
	done'

lint: ## Execute TFLint on all roots
	$(RUN) 'set -e; \
		tflint --init --config=$(TFLINT_CONFIG); \
		tflint --chdir=terraform --recursive --config=$(TFLINT_CONFIG)'

security: ## Execute Checkov security scanning
	$(RUN) 'checkov -d terraform --config-file $(CHECKOV_CONFIG)'

check: ## Run the full validation workflow in a single container
	$(RUN) 'set -e; \
		echo "== fmt-check =="; terraform fmt -check -recursive terraform; \
		for d in $(TF_ROOTS); do \
			echo "== init $$d =="; terraform -chdir=$$d init -backend=false -input=false >/dev/null; \
			echo "== validate $$d =="; terraform -chdir=$$d validate; \
		done; \
		echo "== tflint =="; tflint --init --config=$(TFLINT_CONFIG); \
		tflint --chdir=terraform --recursive --config=$(TFLINT_CONFIG); \
		echo "== checkov =="; checkov -d terraform --config-file $(CHECKOV_CONFIG)'
