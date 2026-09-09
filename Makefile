CLUSTER   := eks-observable-platform
REGION    := ap-south-2
CHART     := application/helm

# Namespace the k6 gates run in. The workflows run them in the same namespace
# as the release under test, so the in-cluster service name resolves.
NS        ?= app-prod

.DEFAULT_GOAL := help
.PHONY: help init plan apply kubeconfig nodes platform monitoring ingress-controller \
        ingress grafana prometheus app-dev app-prod smoke load load-podinfo \
        chaos-oom chaos-drain status verify clean-ingress destroy test lint

help:  ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

# ---------- infrastructure ----------

init:  ## terraform init
	terraform init

plan:  ## terraform plan
	terraform plan

apply:  ## Create the cluster and supporting AWS resources
	terraform apply

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
	@echo
	@echo "Loki registers itself as a default data source, which conflicts with"
	@echo "Prometheus and crashes Grafana. Set isDefault to false, then restart:"
	@echo "  kubectl edit configmap loki-loki-stack -n monitoring"
	@echo "  kubectl rollout restart deployment kps-grafana -n monitoring"

ingress-controller:  ## Install the AWS Load Balancer Controller
	eksctl utils associate-iam-oidc-provider \
	  --region $(REGION) --cluster $(CLUSTER) --approve
	eksctl create iamserviceaccount \
	  --cluster=$(CLUSTER) --region=$(REGION) \
	  --namespace=kube-system --name=aws-load-balancer-controller \
	  --attach-policy-arn=$$(aws iam list-policies --scope Local \
	    --query "Policies[?PolicyName=='AWSLoadBalancerControllerIAMPolicy'].Arn" \
	    --output text) --approve
	helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
	  -n kube-system \
	  --set clusterName=$(CLUSTER) \
	  --set serviceAccount.create=false \
	  --set serviceAccount.name=aws-load-balancer-controller \
	  --set region=$(REGION) \
	  --set vpcId=$$(aws eks describe-cluster --name $(CLUSTER) \
	    --region $(REGION) --query "cluster.resourcesVpcConfig.vpcId" --output text)

ingress:  ## Create the podinfo ingress and wait for the ALB
	kubectl apply -f k8s/manual/ingress.yaml
	kubectl get ingress -n manual-managed -w

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

lint:  ## Run the same checks as the pull-request workflow
	terraform fmt -check -recursive
	terraform validate
	helm lint $(CHART) -f $(CHART)/values-dev.yaml
	helm lint $(CHART) -f $(CHART)/values-prod.yaml

# The job manifests carry TARGET=PLACEHOLDER, substituted at apply time so the
# same file works for whichever namespace is being tested.
smoke:  ## Run the k6 smoke test (NS=app-prod by default)
	kubectl delete job k6-smoke -n $(NS) --ignore-not-found
	kubectl create configmap k6-smoke-script --from-file=k6/smoke.js -n $(NS) \
	  --dry-run=client -o yaml | kubectl apply -f -
	sed "s|PLACEHOLDER|http://$(NS).$(NS).svc.cluster.local:8080|" k6/smoke-job.yaml \
	  | kubectl apply -n $(NS) -f -
	kubectl wait --for=condition=complete job/k6-smoke -n $(NS) --timeout=120s \
	  && RESULT=pass || RESULT=fail; \
	kubectl logs job/k6-smoke -n $(NS); \
	test "$$RESULT" = pass

load:  ## Run the k6 load test (NS=app-prod by default)
	kubectl delete job k6-load -n $(NS) --ignore-not-found
	kubectl create configmap k6-load-script --from-file=k6/load.js -n $(NS) \
	  --dry-run=client -o yaml | kubectl apply -f -
	sed "s|PLACEHOLDER|http://$(NS).$(NS).svc.cluster.local:8080|" k6/load-job.yaml \
	  | kubectl apply -n $(NS) -f -
	kubectl wait --for=condition=complete job/k6-load -n $(NS) --timeout=360s \
	  && RESULT=pass || RESULT=fail; \
	kubectl logs job/k6-load -n $(NS); \
	test "$$RESULT" = pass

load-podinfo:  ## Project 1 load test against podinfo
	kubectl create namespace k6-testing --dry-run=client -o yaml | kubectl apply -f -
	kubectl delete pod k6-load -n k6-testing --ignore-not-found
	kubectl create configmap k6-script --from-file=k6/load-test.js -n k6-testing \
	  --dry-run=client -o yaml | kubectl apply -f -
	kubectl apply -f k6/k6-job.yaml
	kubectl logs -f k6-load -n k6-testing

# ---------- chaos ----------

chaos-oom:  ## Incident 02: memory hog with namespace guardrails
	kubectl apply -f k8s/chaos/memory-hog-deployment.yaml
	kubectl get pods -n manual-managed -w

chaos-drain:  ## Incident 04: drain the node hosting podinfo
	@NODE=$$(kubectl get pods -n manual-managed -l app=podinfo \
	  -o jsonpath='{.items[0].spec.nodeName}'); \
	echo "draining $$NODE"; \
	kubectl drain $$NODE --ignore-daemonsets --delete-emptydir-data

# ---------- verification ----------

status:  ## Show pods across all project namespaces
	@for ns in manual-managed monitoring app-dev app-prod k6-testing; do \
	  echo "--- $$ns"; \
	  kubectl get pods -n $$ns 2>/dev/null || echo "  (absent)"; \
	done

verify:  ## Check whether any load balancers remain in the cluster VPC
	@VPC=$$(aws eks describe-cluster --name $(CLUSTER) --region $(REGION) \
	  --query "cluster.resourcesVpcConfig.vpcId" --output text 2>/dev/null); \
	if [ -z "$$VPC" ] || [ "$$VPC" = "None" ]; then \
	  echo "cluster not found; nothing to check"; \
	else \
	  aws elbv2 describe-load-balancers --region $(REGION) \
	    --query "LoadBalancers[?VpcId=='$$VPC'].LoadBalancerName" --output text; \
	fi

# ---------- teardown ----------

# The load balancer controller creates ALBs that terraform does not manage.
# If the cluster goes first the controller is gone and nothing can delete them,
# and the VPC delete then fails on the ENIs the ALB still holds.
clean-ingress:  ## Delete everything that owns an ALB, then wait for it to go
	-kubectl delete -f k8s/manual/ingress.yaml --ignore-not-found
	-helm uninstall app-prod -n app-prod
	-helm uninstall app-dev -n app-dev
	@echo "waiting for load balancers to disappear..."
	@VPC=$$(aws eks describe-cluster --name $(CLUSTER) --region $(REGION) \
	  --query "cluster.resourcesVpcConfig.vpcId" --output text); \
	for i in $$(seq 1 30); do \
	  COUNT=$$(aws elbv2 describe-load-balancers --region $(REGION) \
	    --query "length(LoadBalancers[?VpcId=='$$VPC'])" --output text); \
	  if [ "$$COUNT" = "0" ]; then echo "clear"; exit 0; fi; \
	  echo "  $$COUNT remaining"; sleep 10; \
	done; \
	echo "load balancers still present after 5 minutes - check before destroying"; \
	exit 1

destroy: clean-ingress  ## Ordered teardown: ALBs, then eksctl stack, then terraform
	-eksctl delete iamserviceaccount \
	  --cluster=$(CLUSTER) --region=$(REGION) \
	  --namespace=kube-system --name=aws-load-balancer-controller
	terraform destroy
