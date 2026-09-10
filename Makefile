CLUSTER     := eks-observable-platform
REGION      := ap-south-2
CHART       := application/helm

# Keep the IAM policy, controller app version, and Helm chart on a verified
# compatible set. Chart 1.9.2 declares appVersion v2.9.2. Bump together.
LBC_VERSION       := v2.9.2
LBC_CHART_VERSION := 1.9.2

# Namespace the k6 gates run in. The workflows run them in the same namespace
# as the release under test, so the in-cluster service name resolves.
NS        ?= app-prod

.DEFAULT_GOAL := help
.PHONY: help init plan apply kubeconfig nodes platform monitoring ingress-controller \
        ingress grafana prometheus app-dev app-prod smoke load load-podinfo \
        chaos-oom chaos-drain chaos-drain-revert status verify clean-ingress destroy test lint

help:  ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

# ---------- infrastructure ----------

init:  ## terraform init
	terraform -chdir=terraform init

plan:  ## terraform plan
	terraform -chdir=terraform plan

apply:  ## Create the cluster and supporting AWS resources
	terraform -chdir=terraform apply

kubeconfig:  ## Point kubectl at the cluster
	aws eks update-kubeconfig --region $(REGION) --name $(CLUSTER)

nodes:  ## List cluster nodes
	kubectl get nodes

# ---------- platform ----------

platform:  ## Namespaces, podinfo, guardrails, metrics-server, RBAC
	kubectl create namespace manual-managed --dry-run=client -o yaml | kubectl apply -f -
	kubectl apply -f k8s/manual/deployment-v2-with-limits.yaml
	kubectl apply -f k8s/manual/service.yaml
	kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
	kubectl apply -f k8s/manual/limitrange.yaml
	kubectl apply -f k8s/manual/resourcequota.yaml
	kubectl apply -f k8s/manual/pdb.yaml
	# deploy-roles.yaml creates namespaced Role/RoleBinding objects in
	# app-dev and app-prod. The manual Helm targets can create them, but the CI
	# workflows expect them to exist already. Creating them here (idempotently)
	# lets RBAC be applied during cluster setup before any application deploy.
	kubectl create namespace app-dev --dry-run=client -o yaml | kubectl apply -f -
	kubectl create namespace app-prod --dry-run=client -o yaml | kubectl apply -f -
	kubectl apply -f k8s/rbac/deploy-roles.yaml

monitoring:  ## Install Prometheus, Grafana, Loki, alert rules and dashboards
	helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
	helm repo add grafana https://grafana.github.io/helm-charts
	helm repo add eks https://aws.github.io/eks-charts
	helm repo update
	kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
	helm upgrade --install kps prometheus-community/kube-prometheus-stack \
	  -n monitoring -f observability/kube-prom-stack-values.yaml
	kubectl apply -f observability/podinfo-servicemonitor.yaml
	kubectl apply -f observability/podinfo-alert-rules.yaml
	kubectl apply -f observability/app-alert-rules.yaml
	kubectl apply -f observability/grafana-dashboard-configmap.yaml
	helm upgrade --install loki grafana/loki-stack \
	  -n monitoring -f observability/loki-values.yaml

ingress-controller:  ## Install the AWS Load Balancer Controller
	# Added here too (not just in `monitoring`) so this target works even if
	# it's the first thing run on a fresh cluster.
	helm repo add eks https://aws.github.io/eks-charts
	helm repo update
	eksctl utils associate-iam-oidc-provider \
	  --region $(REGION) --cluster $(CLUSTER) --approve
	eksctl create iamserviceaccount \
	  --cluster=$(CLUSTER) --region=$(REGION) \
	  --namespace=kube-system --name=aws-load-balancer-controller \
	  --attach-policy-arn=$$(aws iam list-policies --scope Local \
	    --query "Policies[?PolicyName=='AWSLoadBalancerControllerIAMPolicy'].Arn" \
	    --output text) --approve
	# Pin both chart and controller image. The chart and app version are
	# versioned separately; 1.9.2 is the verified chart for controller v2.9.2.
	helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
	  -n kube-system \
	  --version $(LBC_CHART_VERSION) \
	  --set clusterName=$(CLUSTER) \
	  --set serviceAccount.create=false \
	  --set serviceAccount.name=aws-load-balancer-controller \
	  --set region=$(REGION) \
	  --set image.tag=$(LBC_VERSION) \
	  --set vpcId=$$(aws eks describe-cluster --name $(CLUSTER) \
	    --region $(REGION) --query "cluster.resourcesVpcConfig.vpcId" --output text)
	# Helm can return before the admission webhook is ready. Wait for the
	# controller deployment so an immediate `make ingress` cannot race it.
	kubectl -n kube-system rollout status \
	  deployment/aws-load-balancer-controller \
	  --timeout=180s

ingress:  ## Create the podinfo ingress and wait for the ALB hostname
	kubectl apply -f k8s/manual/ingress.yaml
	@echo "waiting for the podinfo ALB hostname..."
	@for i in $$(seq 1 60); do \
	  HOST=$$(kubectl get ingress podinfo -n manual-managed \
	    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null); \
	  if [ -n "$$HOST" ]; then \
	    echo "ALB hostname: $$HOST"; \
	    kubectl get ingress podinfo -n manual-managed; \
	    exit 0; \
	  fi; \
	  sleep 3; \
	done; \
	echo "timed out waiting for the podinfo ALB hostname"; \
	kubectl describe ingress podinfo -n manual-managed || true; \
	exit 1

# ---------- access ----------

grafana:  ## Print the admin password and port-forward Grafana to :3000
	@echo "admin password:"
	@kubectl get secret kps-grafana -n monitoring \
	  -o jsonpath='{.data.admin-password}' | base64 -d; echo
	kubectl port-forward -n monitoring svc/kps-grafana 3000:80

prometheus:  ## Port-forward Prometheus to :9090
	kubectl port-forward -n monitoring \
	  svc/kps-kube-prometheus-stack-prometheus 9090:9090

# ---------- application ----------
# CI normally deploys these. Both targets need a tag:
#   make app-dev TAG=v1.8.0

app-dev:  ## Deploy a tag to app-dev (TAG=v1.8.0)
	@test -n "$(TAG)" || { echo "TAG is required, e.g. make app-dev TAG=v1.8.0"; exit 1; }
	helm upgrade --install app-dev $(CHART) \
	  -f $(CHART)/values-dev.yaml \
	  --set image.tag=$(TAG) \
	  --namespace app-dev --create-namespace \
	  --wait --timeout 5m

app-prod:  ## Deploy a tag to app-prod (TAG=v1.8.0)
	@test -n "$(TAG)" || { echo "TAG is required, e.g. make app-prod TAG=v1.8.0"; exit 1; }
	helm upgrade --install app-prod $(CHART) \
	  -f $(CHART)/values-prod.yaml \
	  --set image.tag=$(TAG) \
	  --namespace app-prod --create-namespace \
	  --atomic --wait --timeout 5m

# ---------- testing ----------

test:  ## Run the application unit tests
	cd application && pytest -v

lint:  ## Terraform and Helm lint/validation checks (see also: make test)
	terraform fmt -check -recursive
	# -backend=false skips S3 entirely, so no AWS credentials are needed, but
	# `validate` still needs an initialized working directory to check
	# resource schemas against. Without this, `make lint` fails on a fresh
	# clone even though the same check passes in CI, where
	# hashicorp/setup-terraform + this same init step already ran.
	terraform -chdir=terraform init -backend=false
	terraform -chdir=terraform validate
	helm lint $(CHART) -f $(CHART)/values-dev.yaml
	helm lint $(CHART) -f $(CHART)/values-prod.yaml

# The job manifests carry TARGET=PLACEHOLDER, substituted at apply time so the
# same file works for whichever namespace is being tested.
smoke:  ## Run the k6 smoke test (NS=app-prod by default)
	kubectl delete job k6-smoke -n $(NS) --ignore-not-found
	kubectl create configmap k6-smoke-script --from-file=k6/app/smoke.js -n $(NS) \
	  --dry-run=client -o yaml | kubectl apply -f -
	sed "s|PLACEHOLDER|http://$(NS).$(NS).svc.cluster.local:8080|" k6/app/smoke-job.yaml \
	  | kubectl apply -n $(NS) -f -
	@# See scripts/wait-for-job.sh: `kubectl wait --for=condition=complete`
	@# never returns early on a Failed job, so a fast 20s failure would
	@# otherwise sit here for the full timeout before being reported.
	./scripts/wait-for-job.sh k6-smoke $(NS) 120 \
	  && RESULT=pass || RESULT=fail; \
	kubectl logs job/k6-smoke -n $(NS); \
	test "$$RESULT" = pass

load:  ## Run the k6 load test (NS=app-prod by default)
	kubectl delete job k6-load -n $(NS) --ignore-not-found
	kubectl create configmap k6-load-script --from-file=k6/app/load.js -n $(NS) \
	  --dry-run=client -o yaml | kubectl apply -f -
	sed "s|PLACEHOLDER|http://$(NS).$(NS).svc.cluster.local:8080|" k6/app/load-job.yaml \
	  | kubectl apply -n $(NS) -f -
	./scripts/wait-for-job.sh k6-load $(NS) 360 \
	  && RESULT=pass || RESULT=fail; \
	kubectl logs job/k6-load -n $(NS); \
	test "$$RESULT" = pass

load-podinfo:  ## Project 1 load test against podinfo
	kubectl create namespace k6-testing --dry-run=client -o yaml | kubectl apply -f -
	kubectl delete pod k6-load -n k6-testing --ignore-not-found
	kubectl create configmap k6-script --from-file=k6/podinfo/load-test.js -n k6-testing \
	  --dry-run=client -o yaml | kubectl apply -f -
	kubectl apply -f k6/podinfo/k6-job.yaml
	kubectl logs -f k6-load -n k6-testing

# ---------- chaos ----------

chaos-oom:  ## Incident 02: memory hog with namespace guardrails
	kubectl apply -f k8s/chaos/memory-hog-deployment.yaml
	kubectl get pods -n manual-managed -w

chaos-drain:  ## Incident 04: drain the node hosting podinfo
	@NODE=$$(kubectl get pods -n manual-managed -l app=podinfo \
	  -o jsonpath='{.items[0].spec.nodeName}'); \
	echo "$$NODE" > .last-drained-node; \
	echo "draining $$NODE"; \
	kubectl drain $$NODE --ignore-daemonsets --delete-emptydir-data; \
	echo; \
	echo "$$NODE is now cordoned (SchedulingDisabled), not removed. Run"; \
	echo "'make chaos-drain-revert' to uncordon it BEFORE scaling desired_size"; \
	echo "back down - otherwise the ASG may remove the wrong (new) node and"; \
	echo "leave this cordoned one as the only worker able to run anything."

chaos-drain-revert:  ## Uncordon the node that chaos-drain drained
	@test -f .last-drained-node || { echo "no .last-drained-node found - nothing to revert"; exit 1; }
	@NODE=$$(cat .last-drained-node); \
	echo "uncordoning $$NODE"; \
	kubectl uncordon $$NODE; \
	rm -f .last-drained-node; \
	echo "done. Safe to scale terraform/eks.tf desired_size back down now."

# ---------- verification ----------

status:  ## Show pods across all project namespaces
	@for ns in manual-managed monitoring app-dev app-prod k6-testing; do \
	  echo "--- $$ns"; \
	  kubectl get pods -n $$ns 2>/dev/null || echo "  (absent)"; \
	done

verify:  ## Check ALBs, target groups and security groups in the cluster VPC
	@VPC=$$(aws eks describe-cluster --name $(CLUSTER) --region $(REGION) \
	  --query "cluster.resourcesVpcConfig.vpcId" --output text 2>/dev/null); \
	if [ -z "$$VPC" ] || [ "$$VPC" = "None" ]; then \
	  echo "cluster not found; nothing to check"; \
	else \
	  echo "--- load balancers"; \
	  aws elbv2 describe-load-balancers --region $(REGION) \
	    --query "LoadBalancers[?VpcId=='$$VPC'].[LoadBalancerName,State.Code]" \
	    --output table --no-cli-pager; \
	  echo "--- target groups"; \
	  aws elbv2 describe-target-groups --region $(REGION) \
	    --query "TargetGroups[?VpcId=='$$VPC'].[TargetGroupName,TargetType]" \
	    --output table --no-cli-pager; \
	  echo "--- LBC-owned security groups"; \
	  aws ec2 describe-security-groups --region $(REGION) \
	    --filters Name=vpc-id,Values=$$VPC \
	      Name=tag:elbv2.k8s.aws/cluster,Values=$(CLUSTER) \
	    --query 'SecurityGroups[].{ID:GroupId,Name:GroupName,Description:Description}' \
	    --output table --no-cli-pager; \
	  echo "--- all non-default security groups"; \
	  aws ec2 describe-security-groups --region $(REGION) \
	    --filters Name=vpc-id,Values=$$VPC \
	    --query 'SecurityGroups[?GroupName!=`default`].[GroupId,GroupName]' \
	    --output table --no-cli-pager; \
	fi

# ---------- teardown ----------

# The AWS Load Balancer Controller creates ALBs, target groups and security
# groups outside Terraform. Kubernetes objects must be removed while the
# controller is still running so it can reconcile those AWS resources.
#
# The live teardown test showed that "ALBs = 0" is not sufficient: a target
# group plus the controller-managed frontend/shared-backend security groups can
# remain and block aws_vpc.main with DependencyViolation. clean-ingress therefore
# waits for ALBs, gives the controller time to remove target groups, then safely
# removes any remaining controller-owned target groups/security groups before
# Terraform is allowed to destroy EKS/VPC.
clean-ingress:  ## Remove ALB owners and clear LBC AWS dependencies before Terraform
	@set -eu; \
	VPC=$$(aws eks describe-cluster \
	  --name $(CLUSTER) \
	  --region $(REGION) \
	  --query "cluster.resourcesVpcConfig.vpcId" \
	  --output text); \
	if [ -z "$$VPC" ] || [ "$$VPC" = "None" ]; then \
	  echo "could not determine the cluster VPC - stopping before teardown"; \
	  exit 1; \
	fi; \
	echo "cluster VPC: $$VPC"; \
	echo; \
	echo "removing Kubernetes/Helm objects that own load balancers..."; \
	kubectl delete -f k8s/manual/ingress.yaml \
	  --ignore-not-found --wait=true || exit 1; \
	if helm status app-prod -n app-prod >/dev/null 2>&1; then \
	  helm uninstall app-prod -n app-prod --wait --timeout 5m || exit 1; \
	else \
	  echo "app-prod already absent"; \
	fi; \
	if helm status app-dev -n app-dev >/dev/null 2>&1; then \
	  helm uninstall app-dev -n app-dev --wait --timeout 5m || exit 1; \
	else \
	  echo "app-dev already absent"; \
	fi; \
	echo; \
	echo "waiting for load balancers in $$VPC to disappear..."; \
	LB_CLEAR=false; \
	for i in $$(seq 1 60); do \
	  LB_COUNT=$$(aws elbv2 describe-load-balancers \
	    --region $(REGION) \
	    --query "length(LoadBalancers[?VpcId=='$$VPC'])" \
	    --output text); \
	  echo "  ALBs remaining: $$LB_COUNT"; \
	  if [ "$$LB_COUNT" = "0" ]; then \
	    LB_CLEAR=true; \
	    break; \
	  fi; \
	  sleep 10; \
	done; \
	if [ "$$LB_CLEAR" != "true" ]; then \
	  echo; \
	  echo "load balancers still exist after 10 minutes."; \
	  echo "Stopping while EKS and the controller still exist."; \
	  aws elbv2 describe-load-balancers \
	    --region $(REGION) \
	    --query "LoadBalancers[?VpcId=='$$VPC'].[LoadBalancerName,State.Code]" \
	    --output table --no-cli-pager; \
	  exit 1; \
	fi; \
	echo; \
	echo "ALBs are gone. Giving the controller time to remove target groups..."; \
	TG_CLEAR=false; \
	for i in $$(seq 1 30); do \
	  TG_COUNT=$$(aws elbv2 describe-target-groups \
	    --region $(REGION) \
	    --query "length(TargetGroups[?VpcId=='$$VPC' && starts_with(TargetGroupName, 'k8s-')])" \
	    --output text); \
	  echo "  k8s target groups remaining: $$TG_COUNT"; \
	  if [ "$$TG_COUNT" = "0" ]; then \
	    TG_CLEAR=true; \
	    break; \
	  fi; \
	  sleep 10; \
	done; \
	if [ "$$TG_CLEAR" != "true" ]; then \
	  echo "controller left target groups after 5 minutes; deleting only"; \
	  echo "k8s-* target groups in the dedicated cluster VPC."; \
	  for TG in $$(aws elbv2 describe-target-groups \
	    --region $(REGION) \
	    --query "TargetGroups[?VpcId=='$$VPC' && starts_with(TargetGroupName, 'k8s-')].TargetGroupArn" \
	    --output text); do \
	      echo "deleting target group $$TG"; \
	      aws elbv2 delete-target-group \
	        --region $(REGION) \
	        --target-group-arn "$$TG" \
	        --no-cli-pager || exit 1; \
	  done; \
	fi; \
	echo; \
	echo "checking controller-owned security groups..."; \
	LBC_SGS=$$(aws ec2 describe-security-groups \
	  --region $(REGION) \
	  --filters Name=vpc-id,Values=$$VPC \
	    Name=tag:elbv2.k8s.aws/cluster,Values=$(CLUSTER) \
	  --query 'SecurityGroups[].GroupId' \
	  --output text); \
	if [ -n "$$LBC_SGS" ] && [ "$$LBC_SGS" != "None" ]; then \
	  for SG in $$LBC_SGS; do \
	    echo "deleting LBC security group $$SG"; \
	    if ! aws ec2 delete-security-group \
	      --region $(REGION) \
	      --group-id "$$SG" \
	      --no-cli-pager; then \
	      echo; \
	      echo "could not delete LBC security group $$SG."; \
	      echo "A security-group dependency still exists. Stopping BEFORE"; \
	      echo "EKS/Terraform destruction so it can be inspected safely."; \
	      echo; \
	      aws ec2 describe-security-groups \
	        --region $(REGION) \
	        --group-ids "$$SG" \
	        --output table --no-cli-pager || true; \
	      exit 1; \
	    fi; \
	  done; \
	else \
	  echo "no LBC-owned security groups remain"; \
	fi; \
	echo; \
	echo "final LBC dependency check..."; \
	LB_COUNT=$$(aws elbv2 describe-load-balancers \
	  --region $(REGION) \
	  --query "length(LoadBalancers[?VpcId=='$$VPC'])" \
	  --output text); \
	TG_COUNT=$$(aws elbv2 describe-target-groups \
	  --region $(REGION) \
	  --query "length(TargetGroups[?VpcId=='$$VPC' && starts_with(TargetGroupName, 'k8s-')])" \
	  --output text); \
	SG_COUNT=$$(aws ec2 describe-security-groups \
	  --region $(REGION) \
	  --filters Name=vpc-id,Values=$$VPC \
	    Name=tag:elbv2.k8s.aws/cluster,Values=$(CLUSTER) \
	  --query 'length(SecurityGroups)' \
	  --output text); \
	echo "  ALBs=$$LB_COUNT target-groups=$$TG_COUNT LBC-security-groups=$$SG_COUNT"; \
	if [ "$$LB_COUNT" != "0" ] || [ "$$TG_COUNT" != "0" ] || [ "$$SG_COUNT" != "0" ]; then \
	  echo "LBC AWS dependencies still remain - stopping before Terraform."; \
	  exit 1; \
	fi; \
	echo "LBC cloud dependencies cleared"

destroy: clean-ingress  ## Ordered teardown: LBC AWS deps, eksctl/IRSA OIDC, then Terraform
	@# A bare `-` prefix here would swallow EVERY failure, not just "already
	@# deleted" - including a genuine eksctl failure - and fall straight
	@# into terraform destroy, which is exactly the stranded-resource
	@# ordering problem docs/runbook.md's "Orphaned resources" section
	@# exists to explain. So: tolerate "doesn't exist", stop on anything else.
	@OUTPUT=$$(eksctl delete iamserviceaccount \
	  --cluster=$(CLUSTER) --region=$(REGION) \
	  --namespace=kube-system --name=aws-load-balancer-controller 2>&1); \
	STATUS=$$?; \
	echo "$$OUTPUT"; \
	if [ $$STATUS -ne 0 ] && ! echo "$$OUTPUT" | grep -qiE "not found|does not exist|no such|NoSuchEntity"; then \
	  echo; \
	  echo "eksctl delete iamserviceaccount failed for a reason other than"; \
	  echo "'already gone' - stopping before terraform destroy. Resolve the"; \
	  echo "error above (see docs/runbook.md 'Orphaned resources') and re-run"; \
	  echo "'make destroy'."; \
	  exit 1; \
	fi
	@# eksctl also created the cluster-specific IAM OIDC provider used by IRSA.
	@# It is outside Terraform (the GitHub Actions OIDC provider is Terraform-
	@# managed and is a different resource), so remove only the EKS issuer here.
	@ISSUER=$$(aws eks describe-cluster --name $(CLUSTER) --region $(REGION) \
	  --query "cluster.identity.oidc.issuer" --output text) || { \
	    echo "Could not read the EKS OIDC issuer - stopping before terraform destroy."; exit 1; }; \
	ACCOUNT_ID=$$(aws sts get-caller-identity --query Account --output text) || { \
	  echo "Could not read the AWS account ID - stopping before terraform destroy."; exit 1; }; \
	if [ -z "$$ISSUER" ] || [ "$$ISSUER" = "None" ] || [ -z "$$ACCOUNT_ID" ]; then \
	  echo "Could not build the EKS OIDC provider ARN - stopping before terraform destroy."; \
	  exit 1; \
	fi; \
	OIDC_HOSTPATH=$${ISSUER#https://}; \
	OIDC_ARN="arn:aws:iam::$$ACCOUNT_ID:oidc-provider/$$OIDC_HOSTPATH"; \
	FOUND=$$(aws iam list-open-id-connect-providers \
	  --query "OpenIDConnectProviderList[?Arn=='$$OIDC_ARN'].Arn | [0]" \
	  --output text); \
	STATUS=$$?; \
	if [ $$STATUS -ne 0 ]; then \
	  echo "Could not check the EKS IAM OIDC provider - stopping before terraform destroy."; \
	  exit 1; \
	fi; \
	if [ -n "$$FOUND" ] && [ "$$FOUND" != "None" ]; then \
	  echo "deleting EKS IRSA OIDC provider $$OIDC_ARN"; \
	  aws iam delete-open-id-connect-provider --open-id-connect-provider-arn "$$OIDC_ARN" || exit 1; \
	else \
	  echo "EKS IRSA OIDC provider already absent"; \
	fi
	terraform -chdir=terraform destroy
