SHELL := /usr/bin/env bash

SCENARIO ?= nvme-ext4
WORKLOAD ?= tpcb
SCALE    ?= 15000
DURATION ?= 1800
WARMUP   ?= 300
CLIENTS  ?= 64
JOBS     ?= 16
CLUSTER  ?= false
REGION   ?= us-east-2
INSTANCE_TYPE ?= i7i.4xlarge
USE_SPOT ?= true
BUDGET_USD ?= 30
BUDGET_EMAIL ?=

VALID_SCENARIOS := nvme-ext4 nvme-zfs nvme-zfs-fpi nvme-zfs-rec32k nvme-zfs-rec128k zerofs-standard zerofs-express zerofs-standard-ext4 zerofs-express-ext4 mountpoint
VALID_WORKLOADS := tpcb mixed

.PHONY: help up provision bench fetch down destroy clean smoke validate bake bootstrap analysis-up analysis-shell analysis-down

help:
	@echo "Postgres on S3 vs NVMe benchmark — Makefile targets"
	@echo
	@echo "  make bootstrap                           Create the long-lived results bucket (one-time, idempotent)"
	@echo "  make up          SCENARIO=<s>            Apply Terraform + run Ansible"
	@echo "  make provision   SCENARIO=<s>            Re-run Ansible only"
	@echo "  make bake                                Bake the current instance into a base AMI (one-time)"
	@echo "  make bench       SCENARIO=<s> WORKLOAD=<w>  Run the benchmark on the host"
	@echo "  make fetch       SCENARIO=<s>            S3 sync results back, generate plots"
	@echo "  make down                                Tear down per-scenario infra; results bucket persists"
	@echo "  make destroy                             Tear down everything including the results bucket"
	@echo "  make analysis-up                         Provision the in-region analysis workstation"
	@echo "  make analysis-shell                      Open an interactive SSM session on it"
	@echo "  make analysis-down                       Tear it down"
	@echo "  make smoke                               ~20-min end-to-end check at production concurrency"
	@echo
	@echo "Variables (defaults shown):"
	@echo "  SCENARIO=$(SCENARIO)   one of: $(VALID_SCENARIOS)"
	@echo "  WORKLOAD=$(WORKLOAD)         one of: $(VALID_WORKLOADS)"
	@echo "  SCALE=$(SCALE)            pgbench scale factor"
	@echo "  DURATION=$(DURATION)         steady-state seconds"
	@echo "  WARMUP=$(WARMUP)           warmup seconds (discarded)"
	@echo "  CLIENTS=$(CLIENTS) JOBS=$(JOBS)"
	@echo "  CLUSTER=$(CLUSTER)         set to 'true' for 3-AZ replicated cluster"
	@echo "  REGION=$(REGION)"
	@echo "  BUDGET_USD=$(BUDGET_USD)         AWS Budgets monthly limit (0 to skip)"
	@echo "  BUDGET_EMAIL=$(BUDGET_EMAIL)            optional notification email"

validate:
	@echo "$(VALID_SCENARIOS)" | grep -qw "$(SCENARIO)" \
		|| { echo "ERROR: SCENARIO=$(SCENARIO) not in: $(VALID_SCENARIOS)"; exit 1; }
	@echo "$(VALID_WORKLOADS)" | grep -qw "$(WORKLOAD)" \
		|| { echo "ERROR: WORKLOAD=$(WORKLOAD) not in: $(VALID_WORKLOADS)"; exit 1; }

up: validate
	BUDGET_USD="$(BUDGET_USD)" BUDGET_EMAIL="$(BUDGET_EMAIL)" \
	INSTANCE_TYPE="$(INSTANCE_TYPE)" USE_SPOT="$(USE_SPOT)" \
	    ./scripts/bench-up.sh "$(SCENARIO)" "$(CLUSTER)" "$(REGION)"

provision: validate
	./scripts/bench-up.sh "$(SCENARIO)" "$(CLUSTER)" "$(REGION)" --provision-only

bake:
	./scripts/bench-bake.sh

bench: validate
	./scripts/bench-run.sh \
		--scenario "$(SCENARIO)" \
		--workload "$(WORKLOAD)" \
		--scale "$(SCALE)" \
		--duration "$(DURATION)" \
		--warmup "$(WARMUP)" \
		--clients "$(CLIENTS)" \
		--jobs "$(JOBS)"

fetch: validate
	./scripts/bench-fetch.sh "$(SCENARIO)"

bootstrap:
	./scripts/bench-bootstrap.sh "$(REGION)"

down:
	./scripts/bench-down.sh

destroy:
	./scripts/bench-destroy.sh "$(REGION)"

analysis-up:
	./scripts/analysis-up.sh "$(REGION)"

analysis-shell:
	./scripts/analysis-shell.sh

analysis-down:
	./scripts/analysis-down.sh "$(REGION)"

smoke: validate
	./scripts/bench-up.sh "$(SCENARIO)" false "$(REGION)"
	./scripts/bench-run.sh --scenario "$(SCENARIO)" --workload tpcb \
		--scale 1000 --duration 120 --warmup 120 --clients $(CLIENTS) --jobs $(JOBS)
	./scripts/bench-fetch.sh "$(SCENARIO)" --tag smoke

clean:
	rm -rf results/local results/smoke results/scratch
	rm -rf terraform/.terraform terraform/terraform.tfstate*
	rm -rf analysis/.venv
