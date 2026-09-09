# Runbook

Cluster: `eks-observable-platform`, region `ap-south-2`.

Terraform lives in `terraform/` and is always run manually from a laptop. Only
application delivery is automated — the pipeline never touches infrastructure.

Most steps below have a Makefile target, noted alongside. The commands are kept
here in full because this file explains why each one is needed; the Makefile
only runs them.

## Teardown

Run this before destroying anything:

```bash
make destroy
```

The order matters more than it looks. The AWS Load Balancer Controller creates
ALBs in response to Ingress objects, and Terraform has no record of them. If the
cluster is destroyed first, the controller goes with it and nothing is left that
knows how to delete those load balancers. `terraform destroy` then fails on the
subnets and the internet gateway, because the ALB still holds ENIs and public
addresses in the VPC.

Both projects create an ALB, so both have to be removed:

```bash
# Project 1: the podinfo ingress.
kubectl delete -f k8s/manual/ingress.yaml

# Project 2: the app ingresses, which belong to the Helm releases.
helm uninstall app-prod -n app-prod
helm uninstall app-dev -n app-dev

# Confirm nothing is left before continuing. This must return empty.
VPC=$(aws eks describe-cluster --name eks-observable-platform \
  --region ap-south-2 --query "cluster.resourcesVpcConfig.vpcId" --output text)

aws elbv2 describe-load-balancers --region ap-south-2 \
  --query "LoadBalancers[?VpcId=='$VPC'].LoadBalancerName" --output text

# Terraform doesn't manage this because eksctl created it. It needs a live
# cluster, so it has to run before terraform destroy.
eksctl delete iamserviceaccount \
  --cluster=eks-observable-platform --region=ap-south-2 \
  --namespace=kube-system --name=aws-load-balancer-controller

terraform -chdir=terraform destroy
```

`make destroy` does all of the above and refuses to run Terraform while any load
balancer remains, rather than failing halfway through.

`make verify` reports load balancers and controller-created security groups
still present in the VPC, and is worth running before and after a teardown.

## Orphaned resources after a failed teardown

Three classes of resource are created outside Terraform's graph by components
that need a live cluster to clean up after themselves. Destroy the cluster
first and all three strand, each blocking the next stage of the teardown.

The symptoms are `DependencyViolation` on the subnets,
`has some mapped public address(es)` on the internet gateway, and finally
`DependencyViolation` on the VPC itself.

### 1. The load balancer

Created by the controller in response to an Ingress. Delete it and its target
group directly:

```bash
aws elbv2 describe-load-balancers --region ap-south-2 \
  --query "LoadBalancers[?VpcId=='$VPC'].[LoadBalancerName,LoadBalancerArn]" --output table

aws elbv2 delete-load-balancer --region ap-south-2 --load-balancer-arn <arn>

aws elbv2 describe-target-groups --region ap-south-2 \
  --query "TargetGroups[?VpcId=='$VPC'].TargetGroupArn" --output text

aws elbv2 delete-target-group --region ap-south-2 --target-group-arn <arn>
```

ENIs usually release within a couple of minutes. Any left as `available` can be
deleted directly:

```bash
aws ec2 describe-network-interfaces --region ap-south-2 \
  --filters Name=vpc-id,Values=$VPC \
  --query 'NetworkInterfaces[].[NetworkInterfaceId,Status,Description]' --output table

aws ec2 delete-network-interface --region ap-south-2 --network-interface-id <eni-id>
```

### 2. The controller's security groups

The controller creates two: one for the load balancer, and one shared backend
group attached to pod ENIs. It removes both itself when the Ingress is deleted
and it tears the ALB down — but not when the load balancer is deleted directly
with `delete-load-balancer`. They then block the VPC delete.

```bash
aws ec2 describe-security-groups --region ap-south-2 \
  --filters Name=vpc-id,Values=$VPC \
  --query 'SecurityGroups[?GroupName!=`default`].[GroupId,GroupName]' --output table

aws ec2 delete-security-group --region ap-south-2 --group-id <sg-id>
```

The default group deletes with the VPC and can be ignored. If a group refuses to
delete because another references it, drop the referencing rule first:

```bash
aws ec2 describe-security-groups --region ap-south-2 --group-ids <sg-id> \
  --query 'SecurityGroups[0].IpPermissions' --output json

aws ec2 revoke-security-group-ingress --region ap-south-2 \
  --group-id <sg-id> --source-group <other-sg-id> --protocol -1
```

### 3. The eksctl CloudFormation stack

`eksctl delete iamserviceaccount` talks to the cluster, so once the cluster is
gone that command cannot run and CloudFormation is the only route. The stack
also has termination protection enabled by default:

```bash
STACK=eksctl-eks-observable-platform-addon-iamserviceaccount-kube-system-aws-load-balancer-controller

aws cloudformation list-stacks --region ap-south-2 \
  --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE \
  --query "StackSummaries[?contains(StackName,'eksctl')].[StackName,StackStatus]" --output table

aws cloudformation update-termination-protection --region ap-south-2 \
  --no-enable-termination-protection --stack-name $STACK

aws cloudformation delete-stack --region ap-south-2 --stack-name $STACK
```

Deletion is asynchronous, so allow a minute before checking:

```bash
aws cloudformation describe-stacks --region ap-south-2 \
  --stack-name $STACK --query 'Stacks[0].StackStatus' --output text 2>&1 | tail -1

# And confirm the IAM role went with it
aws iam list-roles \
  --query "Roles[?contains(RoleName,'eksctl-eks-observable-platform')].RoleName" --output text
```

Leaving the stack costs nothing, but the next `eksctl create iamserviceaccount`
collides with a stack of the same name.

## First time only

The IAM policy survives `terraform destroy`, so skip this on rebuilds.

```bash
curl -o iam-policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.9.2/docs/install/iam_policy.json

aws iam create-policy \
  --policy-name AWSLoadBalancerControllerIAMPolicy \
  --policy-document file://iam-policy.json

# To find the ARN later:
aws iam list-policies --scope Local | grep AWSLoadBalancer
```

## Rebuild

### Infrastructure

```bash
terraform -chdir=terraform apply          # make apply

aws eks update-kubeconfig --region ap-south-2 --name eks-observable-platform
kubectl get nodes                         # make kubeconfig, make nodes
```

### Project 1 — podinfo and guardrails

```bash
# make platform
kubectl create namespace manual-managed
kubectl apply -f k8s/manual/deployment-v2-with-limits.yaml
kubectl apply -f k8s/manual/service.yaml
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

kubectl apply -f k8s/manual/limitrange.yaml
kubectl apply -f k8s/manual/resourcequota.yaml
kubectl apply -f k8s/manual/pdb.yaml

# RBAC for the deploy roles used by the pipeline.
kubectl apply -f k8s/rbac/deploy-roles.yaml
```

### Observability

```bash
# make monitoring
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo add eks https://aws.github.io/eks-charts
helm repo update

kubectl create namespace monitoring
helm install kps prometheus-community/kube-prometheus-stack \
  -n monitoring -f observability/kube-prom-stack-values.yaml

kubectl apply -f observability/podinfo-servicemonitor.yaml
kubectl apply -f observability/podinfo-alert-rules.yaml
kubectl apply -f observability/app-alert-rules.yaml
kubectl apply -f observability/grafana-dashboard-configmap.yaml

helm install loki grafana/loki-stack -n monitoring -f observability/loki-values.yaml

# Loki registers itself as a default data source. Two defaults crash Grafana,
# so this has to be flipped to false and Grafana restarted.
kubectl edit configmap loki-loki-stack -n monitoring   # isDefault: true -> false
kubectl rollout restart deployment kps-grafana -n monitoring
```

The admin password is no longer set in the values file. The chart generates one
on install, so retrieve it after each rebuild:

```bash
kubectl get secret kps-grafana -n monitoring \
  -o jsonpath='{.data.admin-password}' | base64 -d; echo

kubectl port-forward -n monitoring svc/kps-grafana 3000:80   # make grafana
```

The app SLO dashboard is carried in a ConfigMap labelled `grafana_dashboard: "1"`,
which the Grafana sidecar loads automatically, so it survives rebuilds. The
podinfo dashboard predates that approach and still has to be imported by hand:

```text
localhost:3000 -> Dashboards -> Import
  -> observability/grafana-dashboards/podinfo-dashboard.json
```

### Ingress controller

```bash
# make ingress-controller

# A new cluster gets a new OIDC issuer, so this runs every time.
eksctl utils associate-iam-oidc-provider \
  --region ap-south-2 --cluster eks-observable-platform --approve

# The policy already exists, so this only attaches it. The command creates an
# IAM role and a Kubernetes service account annotated with that role's ARN,
# which is what makes IRSA work.
#
# If this fails with a stack that already exists, an earlier teardown left the
# eksctl CloudFormation stack behind. See "Orphaned resources" above.
eksctl create iamserviceaccount \
  --cluster=eks-observable-platform --region=ap-south-2 \
  --namespace=kube-system --name=aws-load-balancer-controller \
  --attach-policy-arn=<policy arn> --approve

# create=false tells Helm to use the service account eksctl just made. A
# chart-created one would have no role annotation and no AWS permissions.
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=eks-observable-platform \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set region=ap-south-2 \
  --set vpcId=$(aws eks describe-cluster --name eks-observable-platform \
    --region ap-south-2 --query "cluster.resourcesVpcConfig.vpcId" --output text)

# The ALB address usually takes 2-3 minutes to appear.
kubectl apply -f k8s/manual/ingress.yaml       # make ingress
kubectl get ingress -n manual-managed -w
```

### Project 2 — application namespaces

`make app-dev` and `make app-prod` create these with `--create-namespace`, but
the pipeline does not, so on a fresh cluster they must exist before the first
automated deploy:

```bash
kubectl create namespace app-dev
kubectl create namespace app-prod
```

## Deploying the application

Normally the pipeline does this. `deploy-dev.yml` runs automatically after a
release, and `promote.yml` is triggered manually with a tag.

To deploy by hand:

```bash
make app-dev  TAG=v1.8.0
make app-prod TAG=v1.8.0
```

which runs:

```bash
helm upgrade --install app-prod ./application/helm \
  -f ./application/helm/values-prod.yaml \
  --set image.tag=v1.8.0 \
  --namespace app-prod --atomic --wait --timeout 5m
```

`--atomic` reverts a rollout that fails to complete. It does not catch a release
that deploys cleanly and then serves errors — that is what the k6 gates are for.
See incident 05.

### Rollback

```bash
helm rollback app-prod -n app-prod --wait --timeout 5m
helm history app-prod -n app-prod
```

The rollback is recorded as a new revision rather than removing the failed one,
so the history keeps both. Note that `helm history` shows `APP VERSION 1.0.0` on
every revision, because the image tag is supplied through values rather than the
chart's `appVersion`. Use the Deployed Version panel in Grafana, which reads
`app_build_info`, to see which application version is actually running.

## Load testing

### Project 2 — smoke and load against the app

Both run as Jobs in the same namespace as the release under test, so the
in-cluster service name resolves. The manifests carry `TARGET=PLACEHOLDER`,
substituted at apply time.

```bash
make smoke NS=app-prod
make load  NS=app-prod
```

The smoke test is a fast check that fails a bad release in about twenty seconds.
The load test applies sustained traffic and produces a visible curve in Grafana.
The pipeline runs smoke first; if it fails, load is skipped and the rollback
step fires.

### Project 1 — load against podinfo

Runs in its own namespace, so the LimitRange and ResourceQuota don't apply and
its restarts don't show up in the podinfo dashboards.

```bash
# make load-podinfo
kubectl create namespace k6-testing
kubectl create configmap k6-script --from-file=k6/podinfo/load-test.js -n k6-testing
kubectl apply -f k6/podinfo/k6-job.yaml

kubectl logs -f k6-load -n k6-testing
```

## Chaos scenarios

```bash
make chaos-oom      # incident 02: memory hog inside namespace guardrails
```

The drain test needs somewhere for the evicted pods to go. The node group runs
one node by default and allows a maximum of two, so scale up first:

```bash
sed -i 's/desired_size = 1/desired_size = 2/' terraform/eks.tf
terraform -chdir=terraform apply

make chaos-drain    # incident 04

# Revert afterwards. The second node exists only for this test.
sed -i 's/desired_size = 2/desired_size = 1/' terraform/eks.tf
terraform -chdir=terraform apply
```

Without the second node the PodDisruptionBudget blocks the drain indefinitely,
because `minAvailable: 1` cannot be satisfied while the replacement pod has
nowhere to schedule.

## Notes

- The node group has desired size 1 and maximum 2. The second node exists for
  the drain test and is scaled up and back down around it.
- Worker nodes run in public subnets to avoid NAT Gateway cost.
- Loki persistence is disabled; logs do not survive a restart.
- Grafana has no persistent volume, so the admin password is regenerated and
  the podinfo dashboard re-imported on every rebuild.
- `promote.yml` uses `jq`, so it is required on any machine running the
  equivalent steps by hand.
