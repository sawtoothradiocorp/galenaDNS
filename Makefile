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

.PHONY: help init fmt check plan apply deploy test audit destroy mobileconfig ssh nodes tunnel \
	monitor-deploy monitor-key monitor-check

help: ## Show this help
	@echo "galena-dns"
	@echo
	@grep -hE '^[a-z][a-zA-Z0-9_-]*:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*?## "}{printf "  \033[1m%-14s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "Required environment:"
	@echo "  HCLOUD_TOKEN            Hetzner Cloud API token (read+write)       [plan/apply/destroy/deploy]"
	@echo "  aws_profile (tfvars)    SSO profile: Route 53 records + checks     [plan/apply/destroy/deploy]"
	@echo "  AWS_ACCESS_KEY_ID       TXT-only ACME key, installed on the nodes  [deploy]"
	@echo "  AWS_SECRET_ACCESS_KEY   its secret                                 [deploy]"

# --------------------------------------------------------------------------
# Safe targets
# --------------------------------------------------------------------------

init: ## terraform init
	@$(TF) init -input=false

fmt: ## Format Terraform and check shell scripts
	@$(TF) fmt -recursive
	@if command -v shellcheck >/dev/null; then \
		shellcheck -S warning node/bin/*.sh node/bootstrap.sh scripts/*.sh monitor/install.sh && echo "shellcheck: clean"; \
	else echo "shellcheck not installed (brew install shellcheck) — skipping"; fi
	@for f in node/bin/*.sh node/bootstrap.sh scripts/*.sh monitor/install.sh; do bash -n "$$f"; done
	@python3 -m py_compile monitor/galena-probe && rm -rf monitor/__pycache__
	@echo "bash -n: clean"

check: ## Validate everything that can be checked without spending money
	@$(TF) fmt -check -recursive
	@$(TF) validate
	@$(MAKE) --no-print-directory fmt
	@echo "OK"

plan: ## Show what would be created (no changes, no cost; needs AWS creds to read the zone)
	@$(TF) plan -input=false

nodes: ## Print node addresses, the DNS records, and whether failover is live
	@$(TF) output -raw deploy_hint 2>/dev/null || true
	@echo
	@$(TF) output dns_records
	@echo
	@printf 'failover: '; $(TF) output -raw dns_failover 2>/dev/null || echo unknown
	@echo

# --------------------------------------------------------------------------
# Billable — both prompt first
# --------------------------------------------------------------------------

apply: ## Create/update infrastructure (PROMPTS — this costs money)
	@$(TF) plan -input=false -out=.tfplan
	@echo
	@echo "This creates billable Hetzner resources, and billable Route 53 health"
	@echo "checks when enable_dns_failover is on."
	@echo "Estimated cost: $$($(TF) output -raw estimated_monthly_cost 2>/dev/null || echo 'run make plan first')"
	@echo
	@[ -t 0 ] || { \
	  echo "Not attached to a terminal, so there is nothing to confirm on."; \
	  echo "Run this target from an interactive shell — the prompt is the whole point."; \
	  rm -f terraform/.tfplan; exit 1; }
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
	@[ -t 0 ] || { \
	  echo "Not attached to a terminal, so there is nothing to confirm on."; \
	  echo "Run this target from an interactive shell — the prompt is the whole point."; \
	  exit 1; }
	@read -r -p 'Type "destroy" to continue: ' a; [ "$$a" = destroy ] || { echo "Aborted."; exit 1; }
	@d=$$($(TF) output -raw domain); \
		read -r -p "Really? This cannot be undone. Type $$d to confirm: " b; \
		[ "$$b" = "$$d" ] || { echo "Did not match. Aborted."; exit 1; }
	@$(TF) destroy -input=false -auto-approve

# --------------------------------------------------------------------------
# Configuration
# --------------------------------------------------------------------------

deploy: ## Push node/ and run bootstrap.sh on every node
	@: $${AWS_ACCESS_KEY_ID:?must be set — IAM key with Route 53 access for ACME DNS-01}
	@: $${AWS_SECRET_ACCESS_KEY:?must be set — secret for AWS_ACCESS_KEY_ID}
	@# AWS_SESSION_TOKEN means these are temporary STS/SSO credentials. They would
	@# issue a certificate today and then expire, so renewal would fail silently in
	@# hours and dnsdist would serve an expired certificate. Refuse them.
	@if [ -n "$${AWS_SESSION_TOKEN:-}" ]; then \
		echo "ERROR: AWS_SESSION_TOKEN is set, so these are temporary SSO/STS credentials."; \
		echo "       certbot renewal runs unattended for years and these expire in hours,"; \
		echo "       which would break renewal silently. Use a long-lived IAM user key"; \
		echo "       scoped to TXT records only (see README), or set manage_dns_records=false"; \
		echo "       and handle ACME yourself."; \
		exit 1; \
	fi
	@# node.env and rpz-manifest.tsv below come from `terraform output`, and outputs
	@# live in STATE, not in the config. So a change to terraform.tfvars or
	@# variables.tf does NOT reach a node until `make apply` writes the recomputed
	@# outputs to state — and without this guard `make deploy` pushes the previous
	@# values and reports success, which is exactly how a posture change can appear
	@# to deploy while the node keeps running the old one. `plan -detailed-exitcode`
	@# exits 2 when anything, outputs included, is not current.
	@$(TF) plan -input=false -detailed-exitcode >/dev/null 2>&1; \
	case $$? in \
		0) ;; \
		2) echo "ERROR: Terraform state is behind the configuration, so the settings"; \
		   echo "       pushed to the node would be the PREVIOUS ones. Run 'make apply'"; \
		   echo "       first (it may report no infrastructure changes — outputs still"; \
		   echo "       need to be written to state), then 'make deploy'."; \
		   echo "       See what differs with: make plan"; \
		   exit 1 ;; \
		*) echo "ERROR: 'terraform plan' failed, so whether the settings about to be"; \
		   echo "       pushed are current cannot be determined. Refusing rather than"; \
		   echo "       deploying possibly-stale config. Common cause: expired AWS SSO"; \
		   echo "       credentials — run 'aws sso login --profile <name>'."; \
		   echo "       Diagnose with: make plan"; \
		   exit 1 ;; \
	esac
	@ips=$$($(TF) output -json nodes | python3 -c 'import json,sys;[print(v["ipv4"]) for v in json.load(sys.stdin).values()]'); \
	[ -n "$$ips" ] || { echo "No nodes. Run 'make apply' first."; exit 1; }; \
	for ip in $$ips; do \
		echo "==> $$ip"; \
		echo "    waiting for cloud-init"; \
		ready=0; \
		for _ in $$(seq 1 60); do \
			if ssh $(SSH_OPT) "root@$$ip" 'cloud-init status 2>/dev/null | grep -qE "status: (done|disabled)"' 2>/dev/null; then ready=1; break; fi; \
			sleep 10; \
		done; \
		[ "$$ready" = 1 ] || { echo "    cloud-init did not finish in 10m"; exit 1; }; \
		echo "    syncing config"; \
		rsync -az --delete \
			--exclude node.env --exclude rpz-manifest.tsv --exclude .cloud-init-complete \
			-e "ssh $(SSH_OPT)" node/ "root@$$ip:$(REMOTE)/"; \
		echo "    pushing rendered settings"; \
		{ $(TF) output -raw node_env; echo; } | ssh $(SSH_OPT) "root@$$ip" 'cat > $(REMOTE)/node.env'; \
		{ $(TF) output -raw rpz_manifest; echo; } | ssh $(SSH_OPT) "root@$$ip" 'cat > $(REMOTE)/rpz-manifest.tsv'; \
		echo "    installing ACME credentials"; \
		printf '[default]\naws_access_key_id = %s\naws_secret_access_key = %s\nregion = %s\n' \
			"$$AWS_ACCESS_KEY_ID" "$$AWS_SECRET_ACCESS_KEY" "$${AWS_DEFAULT_REGION:-us-east-1}" \
			| ssh $(SSH_OPT) "root@$$ip" 'install -d -m 0755 /etc/letsencrypt && umask 077 && cat > /etc/letsencrypt/aws.credentials'; \
		echo "    running bootstrap"; \
		ssh $(SSH_OPT) -t "root@$$ip" "bash $(REMOTE)/bootstrap.sh"; \
	done
	@echo
	@echo "Deployed. Next: make audit && make test"

audit: ## Run the privacy audit on EVERY node
	@# `for` over a command substitution, and `ssh -n`, for two separate reasons —
	@# this target had both bugs and reported a clean pass with both of them.
	@#
	@# ssh reads its own stdin. Inside `... | while read -r ip`, that stdin IS the
	@# pipe carrying the remaining addresses, so the first ssh swallowed the rest
	@# and only ONE node was ever audited. Silently, with exit 0. `ssh -n` points
	@# its stdin at /dev/null; the `for` removes the shared pipe entirely.
	@#
	@# A piped `while` also runs in a subshell, so rc=1 set inside it was lost and
	@# a node that FAILED its audit still exited 0. Same trap as `test` below,
	@# which was written to avoid it while this one was not.
	@nodes=$$($(TF) output -json nodes | python3 -c 'import json,sys;[print(k+","+v["ipv4"]) for k,v in json.load(sys.stdin).items()]'); \
	[ -n "$$nodes" ] || { echo "No nodes. Run 'make apply' first."; exit 1; }; \
	rc=0; \
	for entry in $$nodes; do \
		name=$${entry%%,*}; ip=$${entry#*,}; \
		echo; echo "==> $$name ($$ip)"; \
		ssh -n $(SSH_OPT) "root@$$ip" "bash $(REMOTE)/bin/privacy-audit.sh" || rc=1; \
	done; \
	[ $$rc -eq 0 ] || { echo; echo "At least one node FAILED the audit."; exit 1; }

test: ## Test EVERY node from this machine (ARGS="--include-ratelimit" for the rate-limit test)
	@# One node at a time, by address. Testing the hostname alone would exercise
	@# whichever node DNS happened to return and silently skip the others — a
	@# second node that came up broken would still look healthy here.
	@# `for` over a command substitution, not a pipe into `while`: a piped while
	@# runs in a subshell, so rc=1 would be lost and a failing node would exit 0.
	@domain=$$($(TF) output -raw domain); \
	feeds=$$($(TF) output -json rpz_feed_urls | python3 -c 'import json,sys;[print("--feed",u) for u in json.load(sys.stdin)]' | tr "\n" " "); \
	nodes=$$($(TF) output -json nodes | python3 -c 'import json,sys;[print(k+","+v["ipv4"]) for k,v in json.load(sys.stdin).items()]'); \
	read -r rate tunnel < <($(TF) output -raw node_env | python3 -c 'import sys,re;e=dict(re.findall(r"^(\w+)=\"(.*)\"$$",sys.stdin.read(),re.M));print(e["GALENA_MAX_QPS_PER_IP"]+"/"+e["GALENA_MAX_QPS_BURST_PER_IP"], e["GALENA_TUNNEL_MAX_QNAME_BYTES"]+"/"+e["GALENA_TUNNEL_REFUSE_QTYPES"])'); \
	rc=0; \
	for entry in $$nodes; do \
		name=$${entry%%,*}; ip=$${entry#*,}; \
		echo; echo "==> $$name ($$ip)"; \
		scripts/test-resolver.sh --domain "$$domain" --ip "$$ip" --rate "$$rate" --tunnel "$$tunnel" $$feeds $(ARGS) || rc=1; \
	done; \
	[ $$rc -eq 0 ] || { echo; echo "At least one node FAILED."; exit 1; }

# --------------------------------------------------------------------------
# Monitoring — the external prober (monitor/) on var.monitor_host
# --------------------------------------------------------------------------
# Needs alert_email set and applied: terraform/monitoring.tf creates the topic,
# the alarms and the prober's IAM user that these targets hand out.

MON = $(TF) output -json monitoring | python3 -c

monitor-deploy: ## Render the prober's config and copy monitor/ to the monitor host
	@host=$$($(MON) 'import json,sys;m=json.load(sys.stdin);print(m["monitor_host"] if m else "")'); \
	[ -n "$$host" ] || { echo "Monitoring is off: set alert_email in terraform.tfvars and make apply."; exit 1; }; \
	env=$$(mktemp); trap 'rm -f "$$env"' EXIT; \
	{ \
	  echo "# Rendered by 'make monitor-deploy' from Terraform outputs. Not secret."; \
	  echo "GALENA_DOMAIN=$$($(TF) output -raw domain)"; \
	  echo "GALENA_NODES=\"$$($(TF) output -json nodes | python3 -c 'import json,sys;print(" ".join(k+"="+v["ipv4"] for k,v in sorted(json.load(sys.stdin).items())))')\""; \
	  $(MON) 'import json,sys;m=json.load(sys.stdin);print("GALENA_TOPIC_ARN="+m["topic_arn"]);print("GALENA_AWS_REGION="+m["region"]);print("GALENA_METRIC_NAMESPACE="+m["metric_namespace"]);print("GALENA_METRIC_NAME="+m["metric_name"])'; \
	} > "$$env"; \
	echo "==> $$host:galena-probe/"; \
	ssh $(SSH_OPT) "$$host" 'mkdir -p galena-probe'; \
	rsync -a monitor/galena-probe monitor/galena-probe.service monitor/galena-probe.timer monitor/install.sh "$$host:galena-probe/"; \
	rsync -a "$$env" "$$host:galena-probe/probe.env"; \
	echo; \
	echo "Now, from a terminal of your own (sudo will ask for a password):"; \
	echo "  ssh -t $$host 'sudo bash galena-probe/install.sh'"

monitor-key: ## Mint the prober's AWS key and ship it straight to the monitor host
	@# The secret goes from the AWS API into a pipe and out over SSH. It is never
	@# assigned to a shell variable, echoed, or written on this machine — and it is
	@# not an aws_iam_access_key in Terraform, because that stores it in state.
	@host=$$($(MON) 'import json,sys;m=json.load(sys.stdin);print(m["monitor_host"] if m else "")'); \
	[ -n "$$host" ] || { echo "Monitoring is off: set alert_email in terraform.tfvars and make apply."; exit 1; }; \
	user=$$($(MON) 'import json,sys;print(json.load(sys.stdin)["probe_iam_user"])'); \
	prof=$$($(MON) 'import json,sys;print(json.load(sys.stdin)["aws_profile"])'); \
	pargs=$${prof:+--profile $$prof}; \
	existing=$$(aws iam list-access-keys --user-name "$$user" $$pargs --query 'length(AccessKeyMetadata)' --output text); \
	[ "$$existing" -lt 2 ] || { echo "$$user already has 2 keys (the IAM maximum). Delete the unused one first:"; \
	  echo "  aws iam list-access-keys --user-name $$user $$pargs"; exit 1; }; \
	aws iam create-access-key --user-name "$$user" $$pargs --output json \
	  | python3 -c 'import json,sys;k=json.load(sys.stdin)["AccessKey"];sys.stdout.write("[default]\naws_access_key_id = %s\naws_secret_access_key = %s\n" % (k["AccessKeyId"],k["SecretAccessKey"]))' \
	  | ssh $(SSH_OPT) "$$host" 'mkdir -p galena-probe && umask 077 && cat > galena-probe/aws.credentials' \
	  || { echo "FAILED after the key may have been created. List and delete strays with:"; \
	       echo "  aws iam list-access-keys --user-name $$user $$pargs"; exit 1; }; \
	echo "New key for $$user is in $$host:galena-probe/aws.credentials (0600)."; \
	[ "$$existing" -eq 0 ] || echo "The previous key still works. Once install.sh has run, delete it: aws iam list-access-keys --user-name $$user $$pargs"; \
	echo "Install it with:  ssh -t $$host 'sudo bash galena-probe/install.sh'"

monitor-check: ## Run the prober once on the monitor host, printing results only (no alerts)
	@host=$$($(MON) 'import json,sys;m=json.load(sys.stdin);print(m["monitor_host"] if m else "")'); \
	[ -n "$$host" ] || { echo "Monitoring is off."; exit 1; }; \
	ssh $(SSH_OPT) "$$host" 'set -a; . /etc/galena-probe/probe.env; exec /usr/local/lib/galena-probe/galena-probe --dry-run'

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
