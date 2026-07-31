# Runbook — teardown & rebuild

Cluster: `eks-observable-platform` | Region: `ap-south-2` | Account: `756808989597`

---

## TEARDOWN

Order matters — the ALB and the eksctl IAM role are outside Terraform's view.

```bash
# 1. Ingress first (controller must be alive to delete the ALB)
kubectl delete -f k8s/manual/ingress.yaml

# 2. Confirm the ALB is gone before continuing
aws elbv2 describe-load-balancers --region ap-south-2 --output table

# 3. Remove the eksctl IAM role + CloudFormation stack
eksctl delete iamserviceaccount \
  --cluster=eks-observable-platform --region=ap-south-2 \
  --namespace=kube-system --name=aws-load-balancer-controller

# 4. Destroy the rest
terraform destroy
```

Why: deleting the Ingress makes the controller remove the ALB (finalizer holds
the object until it's done). An orphaned ALB keeps billing and blocks VPC
deletion. Terraform can't see the eksctl-made IAM role or CFN stack.

---

## REBUILD

```bash
# 1. Infra (~10-15 min)
terraform apply

# 2. Connect
aws eks update-kubeconfig --region ap-south-2 --name eks-observable-platform
kubectl get nodes

# 3. App
kubectl create namespace manual-managed
kubectl apply -f k8s/manual/deployment-v2-with-limits.yaml
kubectl apply -f k8s/manual/service.yaml
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

# 4. Guardrails
kubectl apply -f k8s/manual/limitrange.yaml
kubectl apply -f k8s/manual/resourcequota.yaml
kubectl apply -f k8s/manual/pdb.yaml

# 5. Helm repos
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo add eks https://aws.github.io/eks-charts
helm repo update

# 6. Monitoring stack (wait for 6 pods Running)
kubectl create namespace monitoring
helm install kps prometheus-community/kube-prometheus-stack \
  -n monitoring -f observability/kube-prom-stack-values.yaml
kubectl get pods -n monitoring

# 7. Scraping + alerts
kubectl apply -f observability/podinfo-servicemonitor.yaml
kubectl apply -f observability/podinfo-alert-rules.yaml

# 8. Loki
helm install loki grafana/loki-stack -n monitoring -f observability/loki-values.yaml

# 8b. MUST DO or Grafana crash-loops (two default datasources)
kubectl edit configmap loki-loki-stack -n monitoring    # isDefault: true -> false
kubectl rollout restart deployment kps-grafana -n monitoring

# 9. OIDC (new cluster = new issuer, must re-associate)
eksctl utils associate-iam-oidc-provider \
  --region ap-south-2 --cluster eks-observable-platform --approve

# 10. IRSA role + SA (policy already exists - do NOT recreate it)
eksctl create iamserviceaccount \
  --cluster=eks-observable-platform --region=ap-south-2 \
  --namespace=kube-system --name=aws-load-balancer-controller \
  --attach-policy-arn=arn:aws:iam::756808989597:policy/AWSLoadBalancerControllerIAMPolicy \
  --approve

# 11. ALB controller
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=eks-observable-platform \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set region=ap-south-2 \
  --set vpcId=$(aws eks describe-cluster --name eks-observable-platform \
    --region ap-south-2 --query "cluster.resourcesVpcConfig.vpcId" --output text)

# 12. Ingress (ADDRESS appears in ~2-3 min)
kubectl apply -f k8s/manual/ingress.yaml
kubectl get ingress -n manual-managed -w

# 13. Grafana dashboard - re-import the JSON
kubectl port-forward -n monitoring svc/kps-grafana 3000:80
# localhost:3000 (admin/admin123) -> Dashboards -> New -> Import
# -> observability/grafana-dashboards/podinfo-dashboard.json
```

---

## Survives teardown (don't recreate)

- eksctl binary, helm repos
- **IAM policy** `AWSLoadBalancerControllerIAMPolicy` — reuse the ARN
- S3 state bucket

## Must recreate every time

- OIDC association (new cluster = new issuer URL)
- IRSA role + ServiceAccount
- Grafana dashboard (re-import JSON)

---

## Gotchas

1. Delete Ingress **before** destroy — orphaned ALB bills and blocks VPC deletion.
2. Never delete the ALB controller before the Ingress — finalizer leaves it stuck Terminating.
3. Re-associate OIDC after every rebuild.
4. Don't recreate the IAM policy → `EntityAlreadyExists`.
5. Fix Loki's `isDefault` right after install, or Grafana crash-loops.
6. ALB DNS may not resolve locally at first — `nslookup <alb-dns> 8.8.8.8` and curl the IP.
