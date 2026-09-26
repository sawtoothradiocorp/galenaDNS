# galena-dns — public non-logging encrypted DNS resolver
#
# Nothing in this Makefile creates or destroys billable resources without an
# explicit typed confirmation. `plan`, `fmt`, `check` and `mobileconfig` are safe
# to run at any time.

SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

TF      := terraform -chdir=terraform
SSH_OPT := -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10
REMOTE  := /opt/galena

# Hetzner's API does not publish host keys, so first contact has to trust DNS and
# the network. accept-new pins the key from then on; a later change will fail loudly.

.PHONY: help init fmt check plan apply deploy test audit destroy mobileconfig ssh nodes tunnel

help: ## Show this help
	@echo "galena-dns"
	@echo
	@grep -hE '^[a-z][a-zA-Z0-9_-]*:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*?## "}{printf "  \033[1m%-14s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "Required environment:"
	@echo "  HCLOUD_TOKEN            Hetzner Cloud API token (read+write)   [plan/apply/destroy]"
	@echo "  CLOUDFLARE_API_TOKEN    Zone:DNS:Edit on your zone             [deploy]"

# --------------------------------------------------------------------------
# Safe targets
# --------------------------------------------------------------------------

init: ## terraform init
	@$(TF) init -input=false

fmt: ## Format Terraform and check shell scripts
	@$(TF) fmt -recursive
	@if command -v shellcheck >/dev/null; then \
		shellcheck -S warning node/bin/*.sh node/bootstrap.sh scripts/*.sh && echo "shellcheck: clean"; \
	else echo "shellcheck not installed (brew install shellcheck) — skipping"; fi
	@for f in node/bin/*.sh node/bootstrap.sh scripts/*.sh; do bash -n "$$f"; done
	@echo "bash -n: clean"

check: ## Validate everything that can be checked without spending money
	@$(TF) fmt -check -recursive
	@$(TF) validate
	@$(MAKE) --no-print-directory fmt
	@echo "OK"

plan: ## Show what would be created (no changes, no cost)
	@$(TF) plan -input=false

nodes: ## Print node addresses and the DNS records you must create
	@$(TF) output -raw deploy_hint 2>/dev/null || true
	@echo
	@$(TF) output dns_records

# --------------------------------------------------------------------------
# Billable — both prompt first
# --------------------------------------------------------------------------

apply: ## Create/update infrastructure (PROMPTS — this costs money)
	@$(TF) plan -input=false -out=.tfplan
	@echo
	@echo "This creates billable Hetzner resources."
	@echo "Estimated cost: $$($(TF) output -raw estimated_monthly_eur 2>/dev/null || echo 'run make plan first')"
	@echo
	@read -r -p 'Type "yes" to apply: ' ans; [ "$$ans" = yes ] || { echo "Aborted."; rm -f terraform/.tfplan; exit 1; }
	@$(TF) apply -input=false .tfplan
	@rm -f terraform/.tfplan
	@echo
	@$(MAKE) --no-print-directory nodes

destroy: ## Destroy all infrastructure (PROMPTS TWICE — irreversible)
	@$(TF) plan -destroy -input=false
	@echo
	@echo "This permanently destroys the resolver node(s) and their IP addresses."
	@echo "Clients configured with your hostname will stop resolving."
	@read -r -p 'Type "destroy" to continue: ' a; [ "$$a" = destroy ] || { echo "Aborted."; exit 1; }
	@d=$$($(TF) output -raw domain); \
		read -r -p "Really? This cannot be undone. Type $$d to confirm: " b; \
		[ "$$b" = "$$d" ] || { echo "Did not match. Aborted."; exit 1; }
	@$(TF) destroy -input=false -auto-approve

# --------------------------------------------------------------------------
# Configuration
# --------------------------------------------------------------------------

deploy: ## Push node/ and run bootstrap.sh on every node
	@: $${CLOUDFLARE_API_TOKEN:?must be set — Zone:DNS:Edit token for your zone}
	@ips=$$($(TF) output -json nodes | python3 -c 'import json,sys;[print(v["ipv4"]) for v in json.load(sys.stdin).values()]'); \
	[ -n "$$ips" ] || { echo "No nodes. Run 'make apply' first."; exit 1; }; \
	for ip in $$ips; do \
		echo "==> $$ip"; \
		echo "    waiting for cloud-init"; \
		timeout 600 bash -c "until ssh $(SSH_OPT) root@$$ip 'test -f $(REMOTE)/.cloud-init-complete' 2>/dev/null; do sleep 10; done" \
			|| { echo "    cloud-init did not finish in 10m"; exit 1; }; \
		echo "    syncing config"; \
		rsync -az --delete -e "ssh $(SSH_OPT)" node/ "root@$$ip:$(REMOTE)/"; \
		echo "    installing ACME credentials"; \
		ssh $(SSH_OPT) "root@$$ip" 'install -d -m 0755 /etc/letsencrypt && umask 077 && cat > /etc/letsencrypt/cloudflare.ini' \
			<<< "dns_cloudflare_api_token = $$CLOUDFLARE_API_TOKEN"; \
		echo "    running bootstrap"; \
		ssh $(SSH_OPT) -t "root@$$ip" "bash $(REMOTE)/bootstrap.sh"; \
	done
	@echo
	@echo "Deployed. Next: make audit && make test"

audit: ## Run the privacy audit on every node
	@$(TF) output -json nodes | python3 -c 'import json,sys;[print(v["ipv4"]) for v in json.load(sys.stdin).values()]' \
	| while read -r ip; do \
		echo "==> $$ip"; \
		ssh $(SSH_OPT) "root@$$ip" "bash $(REMOTE)/bin/privacy-audit.sh"; \
	done

test: ## Test the resolver from this machine (ARGS="--include-ratelimit" for the rate-limit test)
	@domain=$$($(TF) output -raw domain); \
	ip=$$($(TF) output -json nodes | python3 -c 'import json,sys;print(list(json.load(sys.stdin).values())[0]["ipv4"])'); \
	feeds=$$($(TF) output -json rpz_feed_urls | python3 -c 'import json,sys;[print("--feed",u) for u in json.load(sys.stdin)]' | tr "\n" " "); \
	scripts/test-resolver.sh --domain "$$domain" --ip "$$ip" $$feeds $(ARGS)

mobileconfig: ## Generate unsigned iOS/macOS DoH + DoT profiles
	@domain=$$($(TF) output -raw domain); \
	scripts/make-mobileconfig.sh --domain "$$domain" --out .

ssh: ## SSH to the first node
	@ip=$$($(TF) output -json nodes | python3 -c 'import json,sys;print(list(json.load(sys.stdin).values())[0]["ipv4"])'); \
	ssh $(SSH_OPT) "root@$$ip"

tunnel: ## Forward dnsdist's localhost metrics to http://127.0.0.1:8083 (needs enable_localhost_metrics)
	@ip=$$($(TF) output -json nodes | python3 -c 'import json,sys;print(list(json.load(sys.stdin).values())[0]["ipv4"])'); \
	echo "http://127.0.0.1:8083 — Ctrl-C to close"; \
	ssh $(SSH_OPT) -N -L 8083:127.0.0.1:8083 "root@$$ip"
