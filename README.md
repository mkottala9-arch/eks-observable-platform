# EKS Observable Platform

An Amazon EKS-based Kubernetes reliability, observability, and application-delivery platform that demonstrates how workloads behave during failures and how production releases can be validated after deployment and automatically rolled back when validation fails.

The project started as a Kubernetes reliability lab using `podinfo` to test memory pressure, resource guardrails, application-level failures, monitoring, and planned node disruption. It was then extended with an owned application, Docker and ECR, Helm-based dev/prod environments, GitHub Actions, OIDC-based AWS access, application SLOs, k6 release gates, and automated rollback.

The result is a single project that covers both sides of operating workloads on Kubernetes: understanding how the platform behaves when something fails, and building a delivery path that can detect and reject a broken release.

## Project Goals

- Provision a repeatable Amazon EKS environment with Terraform
- Understand Kubernetes behaviour during memory pressure, application failure, and node disruption
- Protect workloads with resource requests, limits, namespace guardrails, and disruption budgets
- Collect node, container, Kubernetes, application, and log data
- Build and deploy an owned application through Docker, ECR, Helm, and GitHub Actions
- Use OIDC and namespace-scoped access instead of long-lived AWS deployment credentials
- Validate releases with post-deploy smoke and load tests
- Monitor application success ratio, HTTP errors, latency, build version, and runtime fault state
- Automatically roll back a production promotion when validation fails
- Document each failure with terminal evidence, dashboards, alerts, workflow output, findings, and recovery

## What Was Built

| Area | Implementation |
|---|---|
| Infrastructure | VPC, public subnets, EKS cluster, managed node group, IAM, ECR, GitHub OIDC provider, and EKS Access Entries provisioned with Terraform |
| Reliability foundation | Two-replica `podinfo` workload with resource guardrails, ALB ingress, monitoring, k6 traffic, and controlled failure tests |
| Owned application | Python/Flask application with health, readiness, version, and Prometheus metric endpoints |
| Application delivery | Docker, immutable ECR images, Helm dev/prod configuration, GitHub Actions, release validation, and automated rollback |
| Access control | Separate CI/dev/prod IAM roles, GitHub Actions OIDC, namespace-scoped EKS access, and Kubernetes RBAC |
| Container hardening | Non-root execution, no privilege escalation, read-only root filesystem, dropped Linux capabilities, and writable `/tmp` only |
| Observability | Prometheus, Grafana, Alertmanager, Loki, Promtail, kube-state-metrics, node-exporter, cAdvisor, application metrics, dashboards, and alerts |
| Testing | Separate k6 tests for the original `podinfo` workload and application smoke/load release gates |
| Operations | Makefile targets for infrastructure, setup, deployment, testing, chaos scenarios, verification, and ordered teardown |
| Failure evidence | Five incident reports covering memory failure, guardrails, HTTP errors, node drain, and automated rollback |

## How the Project Evolved

The platform was built in two stages.

### Phase 1 — Kubernetes Reliability and Observability

The first stage used `podinfo` as a known sample application so the tests could focus on Kubernetes behaviour.

1. **Establish the memory-failure baseline**  
   An unbounded workload attempted to allocate 6 GiB. Separate runs produced both container `OOMKilled` and kubelet `Evicted` outcomes.

2. **Add resource guardrails and monitoring**  
   Requests, limits, `LimitRange`, `ResourceQuota`, and alerting were added. Repeated memory failures stayed within the workload boundary, while Grafana and Prometheus exposed the restart activity.

3. **Test application health beyond Kubernetes health**  
   HTTP 500 responses were injected while the pods remained `Running` and `Ready`. Application metrics detected the user-facing failure even though Kubernetes health signals remained normal.

4. **Test planned disruption under load**  
   A worker node was drained while traffic continued. The `PodDisruptionBudget` prevented both replicas from being disrupted together.

### Phase 2 — Application Delivery, SLOs, and Recovery

The second stage added an owned application and a release path around the same EKS platform.

- The application is containerized with Docker and exposes `/healthz`, `/readyz`, `/version`, and `/metrics`
- Version tags create immutable ECR images containing the application version and Git commit
- Development and production use the same image with separate Helm values
- Pull requests run tests, Docker build validation, Terraform validation, Helm lint, and Gitleaks
- Tagged releases are published to ECR through GitHub Actions using OIDC
- Successful releases deploy automatically to `app-dev` and run a k6 smoke test
- Production promotion is manual and protected by the GitHub `production` environment
- Production runs smoke and load validation after the Helm rollout
- Failed validation triggers `helm rollback` to the previous healthy revision
- Prometheus and Grafana track success ratio, HTTP errors, latency, deployed version, and fault mode
- Incident 05 deliberately promoted a bad production configuration and verified detection, alerting, and automated rollback

## What the Experiments Demonstrated

- An unbounded memory workload can end in either `OOMKilled` or kubelet eviction depending on which protection reacts first
- Resource limits can contain a memory failure before it consumes the worker node
- A pod can remain `Running` and `Ready` while the application serves failed responses
- Application metrics are needed for failures that Kubernetes object health cannot see
- Per-replica request metrics can reveal healthy pods that receive little or no live traffic
- A `PodDisruptionBudget` protects availability during voluntary disruption
- A successful Kubernetes rollout does not guarantee correct application behaviour
- Post-deploy gates can reject a release after the rollout itself succeeds
- HTTP status and SLO metrics can expose a broken release even when latency remains normal
- Build-info metrics make the running application version visible during release investigation
- Monitoring provides continuous detection, while the deployment workflow can act immediately during a production promotion

## Architecture

### Platform Architecture

![EKS Observable Platform architecture](docs/eks-observable-platform-architecture.png)

Two public ALBs are used: one for the original `podinfo` workload and one for `app-prod`. `app-dev` remains internal to the cluster.

The VPC contains two public subnets across two Availability Zones for EKS. The managed worker node group runs in one public subnet to keep the lab small and cost-controlled.

### Release and Rollback Flow

![Application release and rollback flow](docs/release-and-rollback-flow.png)

The same versioned image is promoted rather than rebuilt for production. Continuous monitoring observes the application after deployment, while automated rollback is owned by the production promotion workflow when its validation gates fail.

## Platform Design

| Component | Configuration |
|---|---|
| AWS region | `ap-south-2` |
| Terraform backend | S3 remote state with native S3 locking, Terraform `1.10+` |
| VPC | `10.0.0.0/16`, two public subnets across two AZs |
| EKS node group | `m7i-flex.large`, desired/minimum `1`, maximum `2`, running in one public subnet |
| Container registry | ECR with immutable tags, scan-on-push, and untagged-image cleanup |
| Reliability workload | `podinfo`, two replicas in `manual-managed` |
| Development | `app-dev`, one replica, internal service |
| Production | `app-prod`, two replicas, public ALB ingress |
| Application resources | CPU request `50m`, memory request `64Mi`, CPU limit `500m`, memory limit `256Mi` |
| Monitoring | Prometheus, Grafana, Alertmanager, Loki, Promtail |
| CI/CD authentication | GitHub Actions OIDC with separate CI, dev-deploy, and prod-deploy roles |

## Kubernetes Reliability Foundation

The original `podinfo` workload remains in the repository because it provides the failure-testing foundation for Incidents 01–04.

The workload declares:

```yaml
resources:
  requests:
    cpu: 50m
    memory: 64Mi
  limits:
    cpu: 500m
    memory: 256Mi
```

The namespace also includes:

- `LimitRange` defaults and a maximum container memory limit of `512Mi`
- `ResourceQuota` for namespace-level resource control
- `PodDisruptionBudget` with `minAvailable: 1`

The original k6 workload runs in the separate `k6-testing` namespace so load generation does not interfere with the application namespace limits.

## Owned Application and Helm

The second phase uses an owned Flask application.

| Endpoint | Purpose |
|---|---|
| `/` | Main request path used by release validation |
| `/healthz` | Liveness check |
| `/readyz` | Readiness check |
| `/version` | Application version, Git commit, and environment |
| `/metrics` | Prometheus metrics |

The Helm deployment adds rolling updates, startup/liveness/readiness probes, explicit resources, a production PDB, `ServiceMonitor`, and production ALB ingress.

The container is also hardened through:

- `runAsNonRoot: true`
- `runAsUser: 1000`
- `allowPrivilegeEscalation: false`
- `readOnlyRootFilesystem: true`
- all Linux capabilities dropped
- an `emptyDir` mounted only at `/tmp`

Development runs one replica. Production runs two.

## CI/CD and Access Control

The delivery path is split into four GitHub Actions workflows.

| Workflow | Purpose |
|---|---|
| `pull-request.yml` | Unit tests, Docker build, Terraform format/validation, Helm lint, and Gitleaks |
| `release.yml` | Builds version-tagged images and pushes them to ECR |
| `deploy-dev.yml` | Automatically deploys a successful release to `app-dev` and runs a smoke test |
| `promote.yml` | Manually promotes a tested tag to production, runs validation, and rolls back on failure |

GitHub Actions receives short-lived AWS credentials through OIDC rather than long-lived access keys.

Terraform creates separate roles for CI, development deployment, and production deployment. EKS Access Entries scope the deployment roles to their namespaces, while Kubernetes RBAC grants the additional `ServiceMonitor` permissions required by the monitoring CRD.

## Release Validation and Automated Rollback

Helm deploys production with:

```text
--atomic --wait --timeout 5m
```

This protects against rollout failures such as pods that cannot become Ready.

Once the rollout succeeds, k6 validates application behaviour.

### Smoke Gate

The smoke test runs five virtual users for 20 seconds and requires:

```text
HTTP failures = 0%
p95 latency < 500 ms
```

### Load Gate

The load test runs for three minutes:

```text
30s ramp-up to 10 VUs
2m hold at 10 VUs
30s ramp-down
```

Its thresholds are:

```text
HTTP failures < 1%
p95 latency < 1 s
```

Smoke runs first so a fundamentally broken release fails quickly instead of waiting through the three-minute load profile.

If either production validation gate fails, the workflow runs `helm rollback`.

Incident 05 deliberately enabled a bad production configuration. Kubernetes and Helm completed the rollout, but the application success ratio collapsed, the smoke gate failed, application alerts fired, and GitHub Actions restored the previous healthy Helm revision.

![GitHub Actions showing failed validation and automated rollback](incidents/incident-05/github-actions-rollback.png)

## Observability

Prometheus collects platform and application signals from several sources:

| Source | Purpose |
|---|---|
| `kube-state-metrics` | Kubernetes object state, replica status, and restart counters |
| `node-exporter` | Node CPU, memory, filesystem, and network metrics |
| kubelet / cAdvisor | Pod and container resource metrics |
| `podinfo` metrics | Request rate, response status, and application latency for the reliability tests |
| owned application metrics | Request count, latency, build information, and fault-mode state |

The owned application exports:

- `app_requests_total`
- `app_request_latency_seconds`
- `app_build_info`
- `app_fault_mode`

`app_build_info` exposes the real application version, Git commit, and environment, which made the failed `v1.8.0` promotion directly visible in Grafana.

### Application Alerts

| Alert | Detects | Condition |
|---|---|---|
| `AppHighErrorRate` | User-facing HTTP failures | Error ratio above 1% for 2 minutes |
| `AppHighLatency` | Sustained application slowdown | p95 latency above 1 second for 5 minutes |
| `AppFaultModeEnabled` | Bad runtime configuration | Fault mode enabled for 1 minute |
| `AppPodRestarting` | Container instability | Restart detected over a 10-minute window and present for 1 minute |

The SLO dashboard shows success ratio, HTTP 5xx rate, request traffic, p95 latency, deployed version, and fault mode.

Loki and Promtail collect container logs. During the HTTP fault-injection test, application metrics exposed the request failure, while Loki confirmed that the logging pipeline was working and captured the logs emitted by the application.

Grafana's admin password is not hardcoded in Helm values. The chart generates it in a Kubernetes Secret, and the Makefile/runbook retrieve it when access is needed.

### Monitoring and Recovery Evidence

**Container restart monitoring and alerting**

![Grafana dashboard showing container restart monitoring](incidents/incident-02/grafana-dashboard.png)

**Application-level failure while pods remained healthy**

![Grafana dashboard showing HTTP 500 errors while pods remained healthy](incidents/incident-03/grafana-monitoring.png)

**SLO collapse during the broken release**

![Grafana SLO dashboard during the broken release](incidents/incident-05/dashboard-during.png)

**Application error alert during the release failure**

![Prometheus showing the application error-rate alert](incidents/incident-05/prometheus-alert-error-rate.png)

## Failure Experiments and Results

| Incident | Test | Result |
|---|---|---|
| [01 — Unbounded Pod Memory Failure](incidents/incident-01/unbounded-pod-memory-failure.md) | A pod attempted to allocate 6 GiB without requests or limits | Separate runs produced both `OOMKilled` and kubelet `Evicted` outcomes |
| [02 — Guardrails and Monitoring](incidents/incident-02/guardrails-and-monitoring.md) | The memory workload was repeated as a Deployment with namespace policies and monitoring | The failure stayed within the workload boundary, Grafana showed repeated restarts, and the alert moved to `Firing` |
| [03 — Healthy Pods Serving HTTP 500](incidents/incident-03/healthy-pods-serving-errors.md) | Fault injection returned HTTP 500 while probes remained healthy | Application metrics detected the failure while Kubernetes still showed the pods as `Running` and `Ready` |
| [04 — Node Drain Under Load](incidents/incident-04/node-drain-under-load.md) | The original worker node was drained while k6 traffic continued | The PDB prevented both replicas from being disrupted together and the workload moved to the second node |
| [05 — Broken Release and Automated Rollback](incidents/incident-05/automated-rollback.md) | A production-specific configuration caused a successful rollout to serve HTTP 500 responses | SLO and error metrics exposed the failure, the smoke gate failed, alerts fired, and the workflow rolled production back |

Together, the incidents cover workload isolation, node pressure, application correctness, disruption handling, release validation, observability, and automated recovery.

## Intentional Scope

This is a hands-on portfolio platform rather than a production reference architecture.

- Terraform infrastructure provisioning and teardown remain manual; GitHub Actions automates application delivery
- Automated rollback is limited to the production promotion workflow when a k6 smoke or load gate fails
- Prometheus, Grafana, and Alertmanager continuously detect runtime failures, but monitoring alerts do not trigger rollback automatically
- Worker nodes use public subnets and the node group normally runs one worker to keep the lab cost controlled
- Grafana and Loki use non-persistent storage for this lab
- Kubernetes NetworkPolicies were evaluated but not added to the current public-subnet design. With ALB IP targets, permitting ingress from the load balancer would require allowing the relevant subnet address range, which would also make the policy broad. A private-node design would provide a cleaner network boundary, but this lab intentionally uses public worker nodes to avoid NAT Gateway cost
- External Secrets Operator was also evaluated and scoped out. The project has no application secret-management requirement that justifies running an additional operator; the Grafana admin password was removed from Helm values and is chart-generated in a Kubernetes Secret instead

## Makefile and Operations

The Makefile wraps the commands used most often:

| Command | Purpose |
|---|---|
| `make apply` | Create the cluster and supporting AWS resources |
| `make platform` | Deploy `podinfo`, guardrails, Metrics Server, and RBAC |
| `make monitoring` | Install monitoring and apply dashboards and alert rules |
| `make app-dev TAG=vX.Y.Z` / `make app-prod TAG=vX.Y.Z` | Manual application deployment |
| `make test` | Run application unit tests |
| `make lint` | Run Terraform and Helm validation used by CI |
| `make smoke` / `make load` | Run application release gates |
| `make chaos-oom` / `make chaos-drain` | Re-run the main reliability scenarios |
| `make destroy` | Ordered teardown of ALBs, controller resources, and Terraform infrastructure |

The teardown order matters because the AWS Load Balancer Controller creates ALBs outside Terraform's direct resource graph. The Makefile removes ingress owners and waits for the load balancers to disappear before destroying the EKS/VPC infrastructure.

## Repository Structure

```text
.
├── .github/
│   └── workflows/
│       ├── deploy-dev.yml
│       ├── promote.yml
│       ├── pull-request.yml
│       └── release.yml
├── application/
│   ├── helm/
│   │   ├── templates/
│   │   │   ├── deployment.yaml
│   │   │   ├── ingress.yaml
│   │   │   ├── pdb.yaml
│   │   │   ├── service.yaml
│   │   │   └── servicemonitor.yaml
│   │   ├── Chart.yaml
│   │   ├── values-dev.yaml
│   │   ├── values-prod.yaml
│   │   └── values.yaml
│   ├── app.py
│   ├── Dockerfile
│   ├── requirements-dev.txt
│   ├── requirements.txt
│   └── test_app.py
├── docs/
│   ├── eks-observable-platform-architecture.png
│   ├── release-and-rollback-flow.png
│   └── runbook.md
├── incidents/
│   ├── incident-01/
│   ├── incident-02/
│   ├── incident-03/
│   ├── incident-04/
│   └── incident-05/
├── k6/
│   ├── app/
│   │   ├── load-job.yaml
│   │   ├── load.js
│   │   ├── smoke-job.yaml
│   │   └── smoke.js
│   └── podinfo/
│       ├── k6-job.yaml
│       └── load-test.js
├── k8s/
│   ├── chaos/
│   ├── manual/
│   └── rbac/
├── observability/
│   ├── grafana-dashboards/
│   │   ├── app-slo-dashboard.json
│   │   └── podinfo-dashboard.json
│   ├── app-alert-rules.yaml
│   ├── grafana-dashboard-configmap.yaml
│   ├── kube-prom-stack-values.yaml
│   ├── loki-values.yaml
│   ├── podinfo-alert-rules.yaml
│   └── podinfo-servicemonitor.yaml
├── terraform/
│   ├── .terraform.lock.hcl
│   ├── backend.tf
│   ├── ecr.tf
│   ├── eks-access.tf
│   ├── eks.tf
│   ├── iam-ci.tf
│   ├── iam-deploy.tf
│   ├── main.tf
│   ├── oidc.tf
│   └── vpc.tf
├── .gitignore
├── Makefile
└── README.md
```

## Prerequisites

- AWS account and configured AWS CLI credentials for infrastructure administration
- Terraform `1.10+`
- `kubectl`
- Helm
- `eksctl`
- Docker
- Python / `pytest`
- GNU Make
- `jq`
- GitHub repository with the `production` environment approval configured

## Installation and Operations

The complete infrastructure setup, rebuild process, observability installation, ingress-controller setup, manual application deployment, rollback commands, load tests, chaos scenarios, Grafana access, and ordered teardown are documented in [docs/runbook.md](docs/runbook.md).

Normal application delivery is handled through GitHub Actions. Terraform infrastructure remains intentionally manual.

## Lab Notes

- The final production Helm values keep fault mode disabled; it was enabled only during the controlled Incident 05 experiment
- Loki persistence is disabled, so logs do not survive a Loki rebuild
- Grafana has no persistent volume; its admin password is chart-generated and the application SLO dashboard is provisioned from a ConfigMap
- The older `podinfo` dashboard is imported manually after a rebuild
