# Runbook

Cluster: eks-observable-platform, region ap-south-2

## Teardown

```bash
# Delete the ingress first. The controller must be running to delete the ALB.
kubectl delete -f k8s/manual/ingress.yaml

# Check that the ALB is gone before moving on.
aws elbv2 describe-load-balancers --region ap-south-2 --output table

# Terraform doesn't manage this because it was created with eksctl.
eksctl delete iamserviceaccount \
  --cluster=eks-observable-platform --region=ap-south-2 \
  --namespace=kube-system --name=aws-load-balancer-controller

terraform destroy
```

## First time only

The policy survives `terraform destroy`, so skip this on rebuilds.

```bash
curl -o iam-policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.9.2/docs/install/iam_policy.json

aws iam create-policy \
  --policy-name AWSLoadBalancerControllerIAMPolicy \
  --policy-document file://iam-policy.json

# To check the policy ARN: aws iam list-policies --scope Local | grep AWSLoadBalancer
```

## Rebuild

```bash
terraform apply

aws eks update-kubeconfig --region ap-south-2 --name eks-observable-platform
kubectl get nodes

kubectl create namespace manual-managed
kubectl apply -f k8s/manual/deployment-v2-with-limits.yaml
kubectl apply -f k8s/manual/service.yaml
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

kubectl apply -f k8s/manual/limitrange.yaml
kubectl apply -f k8s/manual/resourcequota.yaml
kubectl apply -f k8s/manual/pdb.yaml

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo add eks https://aws.github.io/eks-charts
helm repo update

kubectl create namespace monitoring
helm install kps prometheus-community/kube-prometheus-stack \
  -n monitoring -f observability/kube-prom-stack-values.yaml

kubectl apply -f observability/podinfo-servicemonitor.yaml
kubectl apply -f observability/podinfo-alert-rules.yaml

helm install loki grafana/loki-stack -n monitoring -f observability/loki-values.yaml

# Two default data sources will crash Grafana, so loki should be set to false
kubectl edit configmap loki-loki-stack -n monitoring   # isDefault: true -> false
kubectl rollout restart deployment kps-grafana -n monitoring

# A new cluster gets a new OIDC issuer, so run this every time.
eksctl utils associate-iam-oidc-provider \
  --region ap-south-2 --cluster eks-observable-platform --approve

# The policy already exists, so just attach it.
# This creates an IAM role (with the policy attached) and a Kubernetes
# service account annotated with the role ARN for IRSA.
eksctl create iamserviceaccount \
  --cluster=eks-observable-platform --region=ap-south-2 \
  --namespace=kube-system --name=aws-load-balancer-controller \
  --attach-policy-arn=<policy arn> --approve

# create=false tells Helm to use the existing service account. As a new service account would not have the IAM role annotation.
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=eks-observable-platform \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set region=ap-south-2 \
  --set vpcId=$(aws eks describe-cluster --name eks-observable-platform \
    --region ap-south-2 --query "cluster.resourcesVpcConfig.vpcId" --output text)

# The ALB address usually takes 2–3 minutes to appear.
kubectl apply -f k8s/manual/ingress.yaml
kubectl get ingress -n manual-managed -w

# Grafana has no persistent volume, so re-import the dashboard after each rebuild.
kubectl port-forward -n monitoring svc/kps-grafana 3000:80
# localhost:3000 -> Dashboards -> Import -> observability/grafana-dashboards/podinfo-dashboard.json
```

## k6 load testing

Runs in its own namespace, so the LimitRange and ResourceQuota don't apply, and
its restarts don't appear in the podinfo dashboards.

```bash
kubectl create namespace k6-testing
kubectl create configmap k6-script --from-file=k6/load-test.js -n k6-testing
kubectl apply -f k6/k6-job.yaml

kubectl logs -f k6-load -n k6-testing
```

## Notes
The node group is configured with a desired size of 1 and a maximum size of 2.
The extra node is used for the node drain test.