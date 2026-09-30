# Repository review and architecture notes

Reviewed snapshot: [`f70bce8e2818bf380775b47bd86decf5a6ae46f0`](https://github.com/mkottala9-arch/eks-observable-platform/tree/f70bce8e2818bf380775b47bd86decf5a6ae46f0), the `main` branch fetched on 2026-09-29.

The review covers **all 82 files in that snapshot: 69 text files and 13 PNG images**. Source, configuration, documentation, and captured logs were read; both dashboard JSON files were parsed; the embedded dashboard was compared with its standalone source; all diagrams and incident screenshots were inspected. The new SVG files and this report are additions to that baseline.

This is a source review, with local unit and static checks. It does not establish the current state of an AWS account, a running cluster, GitHub environment protection rules, or previously recorded incidents. Historical screenshots and logs are evidence of earlier runs, not live verification. Runtime code and infrastructure configuration have not been changed by this documentation update.

## What this project implements

This is a Kubernetes reliability lab with an application delivery pipeline. It has two related workloads: a manually managed `podinfo` deployment for failure experiments, and an owned Flask application deployed with Helm into `app-dev` and `app-prod`. It is not a business application with a database or a distributed tracing system.

The Flask process exposes five routes. Request hooks record a counter and latency histogram, while startup gauges expose the build and fault-mode state. The `/` route deliberately returns HTTP 500 when `FAULT_MODE=true`; `/healthz` and `/readyz` still return HTTP 200. This intentional separation is what makes the release validation experiment meaningful: readiness alone cannot detect the business-path failure.

### Provisioning and ownership

| Owner | Resources and responsibility |
|---|---|
| Terraform, invoked manually | VPC, Internet Gateway, public routes and subnets, EKS cluster and worker group, ECR, cluster/node/CI/deploy IAM roles, GitHub OIDC provider, EKS access entries and namespace access policies |
| One-time operator setup | S3 backend bucket and controller IAM policy; GitHub environment/repository settings are external prerequisites |
| `eksctl` and the controller Helm release | Cluster-specific EKS OIDC provider, controller IRSA role/service account, AWS Load Balancer Controller |
| Load Balancer Controller | ALBs, target groups, and associated security groups reconciled from Kubernetes Ingress objects; these are outside Terraform's resource graph |
| `make platform` | Namespaces, manual `podinfo` resources, Metrics Server, resource guardrails, and deployment ServiceMonitor RBAC |
| `make monitoring` | Monitoring Helm releases, custom ServiceMonitors, PrometheusRules, and the application dashboard ConfigMap |
| Application Helm releases | Deployments, Services, optional Ingresses/ServiceMonitors, and conditional PDBs |
| GitHub Actions | Tests, image publication, dev deployment, production promotion, k6 Jobs, and promotion-time recovery |

The ownership split explains the teardown order. Ingress owners and controller-created cloud dependencies must be removed while the controller still exists, followed by eksctl/IRSA resources, then Terraform infrastructure. The backend bucket and pre-created controller policy are separate prerequisites.

### Runtime and data paths

| Path | Actual implementation |
|---|---|
| Public traffic | Separate internet-facing ALBs for `podinfo` and `app-prod`; `target-type: ip` routes directly to pod IPs discovered through the Ingress/Service configuration |
| Internal development | `app-dev` has a ClusterIP Service on 8080 and no Ingress |
| Application gate traffic | k6 Jobs call `http://app-dev.app-dev.svc.cluster.local:8080` or the corresponding `app-prod` Service; these checks bypass the ALB |
| Reliability load | A bare k6 Pod in `k6-testing` calls `podinfo.manual-managed.svc.cluster.local:9898` |
| Application metrics | ServiceMonitors select Services, identify named `http` ports, and configure 15-second `/metrics` scrapes |
| Platform metrics | kube-state-metrics, node-exporter, and kubelet/cAdvisor provide object, node, and container signals through the monitoring stack |
| Alerts | Prometheus evaluates the custom rules and sends alerts to Alertmanager; no external notification destination is configured in the repository |
| Logs | Promtail collects container logs and sends them to Loki; it cannot supply request detail the application never logs |
| Visualization | Grafana queries Prometheus and Loki; the app dashboard is provisioned from a ConfigMap, while the podinfo dashboard is imported manually |
| Image pulling | Worker-node IAM permissions authorize ECR pulls; GitHub deployment roles do not perform the nodes' image downloads |

The VPC spans two public subnets, but the node group is restricted to the first subnet and normally has one worker. All namespaces and monitoring share that worker group. Neither two replicas nor the node group's maximum size of two establishes multi-AZ availability or automatic scaling. No HPA, cluster autoscaler, topology-spread policy, NetworkPolicy, or durable telemetry storage is declared.

### Release and recovery behavior

1. Pull requests to `main` run tests, a Docker build, infrastructure/chart validation, and Gitleaks. This workflow has no AWS OIDC permission.
2. A `v*` tag triggers `release.yml`. An ancestry check requires the tagged commit to be reachable from `main`. The CI role pushes the built image to immutable ECR storage.
3. A successful release triggers `deploy-dev.yml`. It checks out the upstream commit, resolves the version, deploys through Helm, and runs the smoke Job. Failed validation leaves the dev workflow failed; there is no dev rollback step.
4. An operator dispatches `promote.yml` with an existing image tag. The `production` environment is referenced, and its OIDC subject is required by the production role. Required reviewers and branch restrictions must be configured in GitHub separately.
5. The workflow verifies the ECR tag, records the current Helm revision when present, and deploys with `--atomic --wait --timeout 5m`. It then runs smoke followed by load validation.
6. A rollout failure is handled by Helm's atomic behavior. A later k6 failure triggers the explicit recovery step: restore the recorded revision, or uninstall a failed first release. The workflow remains failed after successful recovery.

Prometheus alerts do not call the promotion workflow or cause rollback. Also, the recorded prior revision is a rollback candidate; the workflow does not prove its application health before recording it.

## Findings and follow-up priorities

These are observations from the reviewed code. Suggested changes below are not implemented in this documentation PR.

### 1. Production eligibility does not enforce a successful dev run

**Priority: medium.** [`promote.yml`](../.github/workflows/promote.yml) checks ECR tag existence but never queries the corresponding dev run or a test attestation. An image whose dev smoke test failed can still be selected manually. The default checkout also uses the dispatch ref, rather than resolving the chart and values to the image's source commit. Thus an immutable image does not imply an immutable application-plus-configuration release.

For a stronger promotion contract, associate the image digest, source commit, chart/values revision, and successful dev result in release metadata, then verify that metadata before upgrading production. In the current implementation, selection of a tested image is an operator responsibility.

### 2. Recovery checks rollout readiness but does not re-run functional validation

**Priority: medium.** The `before` step records the current revision from `helm list`; it does not run an application health gate. Recovery uses `helm rollback --wait`, then prints pods and history. Since this application's readiness remains green during fault mode, neither recording the revision nor waiting after rollback proves `/` is healthy.

Record a previously validated release explicitly and run a smoke check after restoration. Keep reporting the rejected promotion as failed, and distinguish successful recovery from failed recovery. The diagrams deliberately say “recorded revision” rather than “verified healthy revision.”

### 3. The exact HTTP 200 check is not an enforced k6 criterion

**Priority: medium.** [`smoke.js`](../k6/app/smoke.js) and [`load.js`](../k6/app/load.js) call `check(res, ...status === 200)` but only put thresholds on `http_req_failed` and duration. A failed check alone does not fail k6, and the default expected-status range includes 200–399. For example, fast HTTP 204 responses could fail the displayed check while passing the configured gates.

If the contract is specifically HTTP 200, enforce a `checks` threshold or configure expected statuses, and test response content where it matters. See the primary documentation for [k6 thresholds](https://grafana.com/docs/k6/latest/using-k6/thresholds/) and [expected response status](https://grafana.com/docs/k6/latest/javascript-api/k6-http/set-response-callback/).

### 4. The gates do not validate the public ingress path

**Priority: medium.** Both app workflows build an internal Service DNS target. They can validate the application while missing ALB listener, target registration, public routing, or DNS failures. `app-prod` Ingress declares no TLS certificate or HTTPS listener configuration and exposes the `/` prefix, including `/version` and `/metrics` on the Flask application.

Keep the fast internal gates, but add an external-path check if public delivery becomes part of the release contract. Configure TLS and route exposure deliberately before treating this lab as a public production service.

### 5. The manual podinfo deployment has no Kubernetes health probes

**Priority: medium.** [`deployment-v2-with-limits.yaml`](../k8s/manual/deployment-v2-with-limits.yaml) defines resources and a port, but no startup, readiness, or liveness probes. Podinfo exposes health endpoints, yet the checked-in manifest does not configure kubelet to call them. Statements in historical incident prose about passing probes should therefore not be read as a guarantee of the current manifest.

If this workload should model application readiness during drain/replacement tests, add explicit probes in a separate change. The new architecture distinguishes the Flask chart's probes from podinfo's resource guardrails.

### 6. Concurrent dev deployments can interfere with each other

**Priority: medium.** [`deploy-dev.yml`](../.github/workflows/deploy-dev.yml) has no concurrency group. Two releases finishing close together can operate on the same `app-dev` Helm release and delete/recreate the same `k6-smoke` Job and ConfigMap. Serialize dev deployment/validation or isolate its resources by run.

Production does have a concurrency group. With the default queue policy, it protects the running promotion but does not promise an unlimited FIFO queue: newer pending runs can replace older pending runs. See [GitHub's concurrency documentation](https://docs.github.com/en/actions/concepts/workflows-and-actions/concurrency).

### 7. Rebuild inputs are only partially pinned

**Priority: medium for reproducibility.** The AWS provider lock and controller chart/image pair are pinned, but monitoring charts have no `--version`, k6 uses `latest`, Metrics Server uses a `latest` manifest URL, EKS has no explicit Kubernetes version, and the Python base image/transitive dependencies are not locked by digest/hash. The two Grafana exports also use different document shapes: the app dashboard has a `dashboard.grafana.app/v2` wrapper; podinfo has a direct `spec` wrapper.

Record tested versions and validate those dashboard formats against the selected Grafana/chart version during rebuilds. The ConfigMap's embedded app dashboard currently matches its standalone JSON exactly; that is a useful invariant to preserve.

### 8. Telemetry has deliberate blind spots

**Priority: low within the lab; material if reused for production.** There is no external alert receiver or persistent telemetry volume configured. The app Docker command does not enable Gunicorn access logging, and `app.py` has no structured request/error logging. The dashboard success ratio counts non-5xx responses as successes, while the gate's displayed check expects 200. Its `noValue: "0"` presentation can also make missing data resemble a measured zero success ratio.

Make the intended success definition explicit, display missing data distinctly, and configure request logging, durable storage, and notification routing only when extending the lab's operational scope. Node/pod availability and missing-scrape detection should be considered alongside the existing custom application rules; the installed stack's defaults depend on its chart version.

### Additional correctness and maintenance notes

- `release.yml` and `deploy-dev.yml` recompute the image version using `git describe --tags`. Explicitly carrying the triggering release tag would avoid ambiguity when multiple tags identify the same commit.
- `scripts/wait-for-job.sh` returns early for terminal Job conditions, but its elapsed counter excludes API-call time and it suppresses `kubectl` errors. Authorization, missing-Job, and transport failures can appear as a generic timeout.
- `k6/podinfo/k6-job.yaml` is a **Pod**, despite its filename, and its script has no thresholds. A completed Pod or zero interrupted iterations is not proof of zero failed HTTP checks. Incident 04's recorded progress output should be interpreted accordingly.
- Historical commands in Incidents 03–04 use `k6/k6-job.yaml`; the current path is `k6/podinfo/k6-job.yaml`. Incident 05 shows an older values path/shape; the current chart uses `application/helm/values-prod.yaml` with nested `app.faultMode`.
- The unbounded memory manifests acquire defaults if applied after the current `LimitRange`. Reproducing Incident 01 requires the isolated pre-guardrail setup; the normal `make chaos-oom` target intentionally reproduces the guarded experiment instead.
- PDBs address voluntary disruption. They do not provide another failure domain, prevent a sudden node loss, or guarantee request correctness. The manual drain experiment requires spare schedulable capacity.

## File-by-file review

Every baseline file appears once in the inventory below. The findings above describe cross-file behavior; these rows explain each file's contribution and its relevant limits.

### Repository entry points and delivery

| File | Detailed role and review notes |
|---|---|
| [`.gitignore`](../.gitignore) | Excludes Terraform working directories, state, variable/override files, CLI configuration, local controller IAM-policy downloads, Python caches, and the drained-node marker. The provider lock remains tracked. Local plan-file exclusions are commented examples, not active blanket rules. |
| [`Makefile`](../Makefile) | Central operational command surface: infrastructure, platform/bootstrap, monitoring, controller installation, app releases, tests, experiments, inspection, and cleanup. Creates app namespaces before ServiceMonitor RBAC. Pins the controller to chart 1.9.2/image v2.9.2. Teardown waits for cloud dependencies and stops on failures. App deploy targets alone do not run the CI promotion gates. |
| [`README.md`](../README.md) | Project narrative, configuration summary, delivery explanation, diagrams, incident evidence, setup prerequisites, and documented lab boundaries. The architecture section now links to this snapshot-based review and the editable diagram sources. |
| [`.github/workflows/pull-request.yml`](../.github/workflows/pull-request.yml) | Four independent jobs: pytest, Docker build, Terraform/Helm validation, and Gitleaks. The lint job initializes Terraform with `-backend=false`; it does not contact the state backend. Repository branch protections determine whether these jobs are required for merging; the YAML only defines their execution. |
| [`.github/workflows/release.yml`](../.github/workflows/release.yml) | Triggered by `v*` tags. Fetches `main`, requires commit ancestry, derives tag/short SHA, assumes the CI OIDC role, then builds and pushes ECR. Ancestry proves reachability from `main`, not independently that a PR was reviewed. Scan-on-push is configured in ECR but scan findings are not a release gate. |
| [`.github/workflows/deploy-dev.yml`](../.github/workflows/deploy-dev.yml) | Triggered by completion of `release`, guarded on success. Checks out the upstream SHA and installs `app-dev` with the dev values. Creates the smoke ConfigMap/Job, waits for a terminal Job condition, prints logs, and fails on bad validation. No concurrency group, `--atomic`, or recovery step is present. |
| [`.github/workflows/promote.yml`](../.github/workflows/promote.yml) | Manual tag selection, production environment, OIDC, ECR existence check, revision capture, atomic Helm deployment, smoke/load gates, and explicit validation-failure recovery. Concurrency prevents simultaneous promotions. Restores the captured revision or removes a failed initial release; neither dev-result enforcement nor a post-rollback smoke gate is implemented. |

### Application and Helm chart

| File | Detailed role and review notes |
|---|---|
| [`application/.gitignore`](../application/.gitignore) | Ignores local Python bytecode directories; overlaps the root rule harmlessly. |
| [`application/app.py`](../application/app.py) | Reads build/environment/fault settings at process startup. Normalizes unknown URL paths to `other` to bound path-label cardinality. Request hooks record method/path/status counts and latency; build/fault gauges initialize once. Implements `/`, `/healthz`, `/readyz`, `/version`, `/metrics`. Fault mode affects only `/`. No persistence, authentication, tracing, or request-log middleware is present. |
| [`application/Dockerfile`](../application/Dockerfile) | Builds from Python 3.12 slim, installs runtime requirements, embeds version/commit arguments, and runs as `appuser`. A single Gunicorn worker serves port 8080, matching the simple in-process Prometheus registry. The chart supplies writable `/tmp` for Gunicorn under a read-only root filesystem. The build is single-stage and has no explicit access-log option. |
| [`application/requirements.txt`](../application/requirements.txt) | Pins Flask 3.0.3, prometheus-client 0.20.0, and Gunicorn 22.0.0. Transitive packages are not locked here. These exact direct versions were used for the local unit-test run. |
| [`application/requirements-dev.txt`](../application/requirements-dev.txt) | Includes the runtime requirements and pytest 8.2.2, keeping test dependencies outside the container's runtime install. |
| [`application/test_app.py`](../application/test_app.py) | Six tests cover health/readiness responses, version fields, both `index_response` outcomes, and metric names. All six passed locally. These are unit tests; they do not exercise Kubernetes deployment, ALB routing, concurrency, or the complete environment-driven fault-mode HTTP path. |
| [`application/helm/Chart.yaml`](../application/helm/Chart.yaml) | Helm v2 application chart, chart version 0.1.0, static appVersion 1.0.0. The running application version comes from the image/build metric; Helm's appVersion column is not the release image version. |
| [`application/helm/values.yaml`](../application/helm/values.yaml) | Defaults to the account-specific ECR repository with an empty required image tag, one replica, fault mode false, and ingress/monitoring disabled. Requests are 50m CPU/64Mi memory; limits are 500m/256Mi. Environment overlays enable selected resources. |
| [`application/helm/values-dev.yaml`](../application/helm/values-dev.yaml) | One replica, `APP_ENV=dev`, fault mode false, ServiceMonitor enabled, Ingress disabled. The replica count means the PDB template emits no object. |
| [`application/helm/values-prod.yaml`](../application/helm/values-prod.yaml) | Two replicas, `APP_ENV=prod`, fault mode false, ServiceMonitor and Ingress enabled. Current checked-in values differ intentionally from the fault-enabled historical experiment. |
| [`application/helm/templates/deployment.yaml`](../application/helm/templates/deployment.yaml) | Uses release-name labels and a required image tag. Rolling update uses zero unavailable and one surge. Applies non-root UID/GID, no privilege escalation, dropped capabilities, read-only root, startup/liveness/readiness probes, resource values, and `/tmp` emptyDir. It defines no affinity, topology spread, autoscaling, or app-specific service account. |
| [`application/helm/templates/service.yaml`](../application/helm/templates/service.yaml) | ClusterIP Service selects release-name pods and exposes named `http` port 8080. The named port connects the ServiceMonitor and the named container port; the Service also supplies the Ingress backend and k6 target. |
| [`application/helm/templates/ingress.yaml`](../application/helm/templates/ingress.yaml) | Conditional `alb` Ingress uses internet-facing IP targets, `/healthz` ALB checks, and a `/` Prefix rule to port 8080. There is no host restriction, TLS/certificate configuration, or path exclusion for metrics/version. |
| [`application/helm/templates/pdb.yaml`](../application/helm/templates/pdb.yaml) | Emits `minAvailable: 1` only when replicas exceed one, so production gets a PDB and default dev does not. The selector matches the release-name pods. |
| [`application/helm/templates/servicemonitor.yaml`](../application/helm/templates/servicemonitor.yaml) | Conditional ServiceMonitor selects the release's Service, scrapes named port `http` at `/metrics` every 15 seconds, and carries the `release: kps` label. Creation depends on the monitoring CRD and deployment-role permissions. |

### Terraform infrastructure and identity

| File | Detailed role and review notes |
|---|---|
| [`terraform/.terraform.lock.hcl`](../terraform/.terraform.lock.hcl) | Locks the AWS provider at 5.100.0 with platform checksums under the `~> 5.0` constraint. Generated dependency metadata, not application logic; it should change through an intentional provider update. |
| [`terraform/backend.tf`](../terraform/backend.tf) | Requires Terraform 1.10+, selects the AWS provider family, and configures encrypted S3 state with native lockfiles. Bucket, key, and region are hardcoded; the bucket must exist before initialization. |
| [`terraform/main.tf`](../terraform/main.tf) | Selects `ap-south-2`, sets default project/learning tags, and defines project name, region, and the GitHub OIDC subject prefix. The trust prefix includes owner/repository IDs; the actual GitHub-issued subject must match this configuration. |
| [`terraform/vpc.tf`](../terraform/vpc.tf) | Creates a DNS-enabled /16 VPC, Internet Gateway, two public /24 subnets in discovered AZs, shared public routes, automatic public IP assignment, and discovery tags for ALBs/EKS. No private subnets, NAT Gateway, or VPC endpoints are declared. |
| [`terraform/eks.tf`](../terraform/eks.tf) | Defines cluster/node trust roles and policies, EKS with API_AND_CONFIG_MAP authentication and bootstrap creator admin, and an on-demand managed node group. Uses both subnets for EKS but only subnet index 0 for workers. Desired/minimum one, maximum two; no Kubernetes version or autoscaler resource is declared. |
| [`terraform/ecr.tf`](../terraform/ecr.tf) | Creates the app repository with immutable tags and scan-on-push, permits force deletion for lab teardown, expires untagged images after seven days, and exports the repository URL. Tagged releases are not selected by that lifecycle rule. |
| [`terraform/oidc.tf`](../terraform/oidc.tf) | Creates the GitHub Actions OIDC provider for the STS audience. This is separate from the cluster-specific OIDC provider that eksctl creates for controller IRSA. |
| [`terraform/iam-ci.tf`](../terraform/iam-ci.tf) | CI trust accepts the configured repository subject prefix and STS audience. Grants ECR authorization plus layer upload/PutImage to the one app repository, and exports the role ARN. This role is for image publication, not Kubernetes deployment. |
| [`terraform/iam-deploy.tf`](../terraform/iam-deploy.tf) | Dev trust requires the main-branch subject; production trust requires the production-environment subject. Both roles get cluster DescribeCluster and ECR read/existence permissions. Kubernetes authorization is provided separately through access entries/policies and RBAC. |
| [`terraform/eks-access.tf`](../terraform/eks-access.tf) | Maps dev/prod IAM roles to distinct Kubernetes groups and associates AmazonEKSEditPolicy with only `app-dev` or `app-prod`. The separation matters because Kubernetes RBAC grants are additive to EKS access policies. |

### Kubernetes workloads, policies, and experiments

| File | Detailed role and review notes |
|---|---|
| [`k8s/manual/deployment-v1-no-limits.yaml`](../k8s/manual/deployment-v1-no-limits.yaml) | Historical two-replica podinfo 6.7.0 baseline without resource requests/limits or probes. Preserved for the incident narrative; `make platform` selects v2 instead. |
| [`k8s/manual/deployment-v2-with-limits.yaml`](../k8s/manual/deployment-v2-with-limits.yaml) | Current two-replica podinfo 6.14.1 deployment with named port 9898 and 50m/64Mi requests, 500m/256Mi limits. Enables the experiment's fault-injection-capable image; still declares no Kubernetes probes or container security context. |
| [`k8s/manual/service.yaml`](../k8s/manual/service.yaml) | ClusterIP Service in `manual-managed`, selecting `app: podinfo`; its label and named port support discovery by the custom ServiceMonitor. |
| [`k8s/manual/ingress.yaml`](../k8s/manual/ingress.yaml) | Public ALB Ingress for the podinfo Service, using direct pod IP targets and `/` Prefix routing. Has no explicit ALB health-check path or HTTPS configuration. |
| [`k8s/manual/limitrange.yaml`](../k8s/manual/limitrange.yaml) | Applies per-container default requests/limits and maximums only in `manual-managed`. Supplies 50m/64Mi requests and 500m/256Mi limits when omitted, with 1 CPU/512Mi maximums. This is why the resource-free memory-hog Deployment becomes bounded. |
| [`k8s/manual/resourcequota.yaml`](../k8s/manual/resourcequota.yaml) | Caps aggregate requests at 1 CPU/1Gi, limits at 2 CPUs/2Gi, and Pod count at ten in the manual namespace. It is not a policy for dev/prod namespaces. |
| [`k8s/manual/pdb.yaml`](../k8s/manual/pdb.yaml) | Selects podinfo pods and requires at least one available during voluntary eviction. Enables the sequential-drain experiment when replacement capacity is present. |
| [`k8s/chaos/memory-hog-unbounded.yaml`](../k8s/chaos/memory-hog-unbounded.yaml) | One-shot stress Pod attempts a 6G allocation without declared resources. Intended for the pre-guardrail baseline; namespace defaults can change its effective behavior after bootstrap. |
| [`k8s/chaos/memory-hog-limited.yaml`](../k8s/chaos/memory-hog-limited.yaml) | One-shot stress Pod with 256Mi memory request and 512Mi limit attempts the same allocation, isolating the effect of the memory cap. `restartPolicy: Never` preserves the terminal outcome. |
| [`k8s/chaos/memory-hog-deployment.yaml`](../k8s/chaos/memory-hog-deployment.yaml) | A repeating Deployment runs the 6G stress case without explicit resources, relying on the LimitRange. Container restart behavior supplies a signal for the namespace restart alert. |
| [`k8s/rbac/deploy-roles.yaml`](../k8s/rbac/deploy-roles.yaml) | Two namespace-specific Roles and RoleBindings grant ServiceMonitor CRUD to the distinct dev/prod access-entry groups. Applied by an administrator during bootstrap; deploy workflows do not create their own RBAC. |

### Load tests and Job coordination

| File | Detailed role and review notes |
|---|---|
| [`k6/app/smoke.js`](../k6/app/smoke.js) | Five VUs repeatedly request `/` for 20 seconds. Thresholds require zero HTTP failures and p95 below 500ms. TARGET is supplied by the Job; the exact-200 check is informational without a checks threshold. |
| [`k6/app/smoke-job.yaml`](../k6/app/smoke-job.yaml) | Creates a no-retry Job with `restartPolicy: Never`, script ConfigMap volume, placeholder TARGET, and 100m/128Mi requests. Namespace is provided by the caller. Uses `grafana/k6:latest`; no resource limits, execution deadline, or finished-Job TTL is declared. |
| [`k6/app/load.js`](../k6/app/load.js) | Ramps to ten VUs for 30s, holds for two minutes, then ramps down for 30s. Requires HTTP failures below 1% and p95 below one second. Has no think time, checks threshold, or `abortOnFail`; thresholds determine the final outcome rather than an immediate mid-run abort. |
| [`k6/app/load-job.yaml`](../k6/app/load-job.yaml) | No-retry load Job with the load-script ConfigMap and substituted TARGET. Requests 200m CPU/256Mi memory; shares the same mutable k6 image and lack of limits/deadline/TTL as the smoke manifest. |
| [`k6/podinfo/load-test.js`](../k6/podinfo/load-test.js) | Three VUs run for 15 minutes against a fixed podinfo Service URL and record status checks. No thresholds are specified, so this is experimental traffic generation rather than an enforced release gate. |
| [`k6/podinfo/k6-job.yaml`](../k6/podinfo/k6-job.yaml) | Despite its filename, declares a bare Pod in `k6-testing`, mounting `k6-script`, with 100m/128Mi requests and no restart. Placement is not pinned, so reproducing the drain experiment requires confirming the load Pod is not on the drained node. |
| [`scripts/wait-for-job.sh`](../scripts/wait-for-job.sh) | Polls `Complete` and `Failed` independently, returning 0/1 promptly for terminal Jobs and 1 on timeout. Used by Make and both deployment workflows to avoid waiting the entire completion timeout for a Job already marked Failed. Errors from `kubectl get` are suppressed. |

### Observability configuration

| File | Detailed role and review notes |
|---|---|
| [`observability/kube-prom-stack-values.yaml`](../observability/kube-prom-stack-values.yaml) | Applies small resource budgets and two-day Prometheus retention; disables Helm-derived restrictions for nil ServiceMonitor/PodMonitor selectors. No storage specification or notification receiver override is provided. Other behavior depends on the unpinned upstream chart defaults. |
| [`observability/loki-values.yaml`](../observability/loki-values.yaml) | Enables Promtail, keeps Loki from replacing Prometheus as Grafana's default datasource, sets lab resource budgets, and explicitly disables Loki persistence. |
| [`observability/podinfo-servicemonitor.yaml`](../observability/podinfo-servicemonitor.yaml) | Selects the podinfo Service inside `manual-managed`, scraping `/metrics` on port `http` every 15 seconds. Its lack of `release: kps` is accommodated by the stack's selector override. |
| [`observability/podinfo-alert-rules.yaml`](../observability/podinfo-alert-rules.yaml) | A kps-labelled PrometheusRule fires after one minute when the five-minute restart increase is positive for any container in `manual-managed`. The rule name says podinfo, but the query intentionally includes the memory-hog workload. |
| [`observability/app-alert-rules.yaml`](../observability/app-alert-rules.yaml) | Defines namespace-grouped `/` 5xx ratio above 1% for 2m, `/` p95 latency above 1s for 5m, fault gauge enabled for 1m, and recent app-namespace restarts for 1m. Rules provide detection independently of the k6 workflow gates. |
| [`observability/grafana-dashboards/app-slo-dashboard.json`](../observability/grafana-dashboards/app-slo-dashboard.json) | Six production-only panels: non-5xx success percentage, 5xx/sec, request rate by status, p95 histogram estimate, deployed version, and fault mode by pod. Uses a v2 dashboard wrapper, Prometheus datasource, three-column auto-grid, browser timezone, and no variables. The 5xx/sec panel does not restrict `path` to `/`, unlike the success/latency panels. |
| [`observability/grafana-dashboard-configmap.yaml`](../observability/grafana-dashboard-configmap.yaml) | Provisioned app dashboard in `monitoring` with `grafana_dashboard: "1"` for sidecar discovery. Its embedded JSON is semantically identical to `app-slo-dashboard.json` at the reviewed snapshot. Both copies need to stay synchronized. |
| [`observability/grafana-dashboards/podinfo-dashboard.json`](../observability/grafana-dashboards/podinfo-dashboard.json) | Five panels for request rate, p95, namespace-wide restarts, podinfo-only restarts, and 5xx/sec. Uses UTC and an auto-grid under a direct `spec` wrapper. The two restart panels have similar names but different query scope. This file is imported manually, not provisioned by the app ConfigMap. |

### Operational documentation and architecture assets

| File | Detailed role and review notes |
|---|---|
| [`docs/runbook.md`](runbook.md) | Explains ownership, backend/controller prerequisites, rebuild order, dashboards, credential recreation, manual deployment, promotion recovery, experiments, and teardown. Historical/simplified command blocks do not all reproduce the latest Makefile checks; for example, `clean-ingress` also validates target-group and controller security-group cleanup. |
| [`docs/eks-observable-platform-architecture.png`](eks-observable-platform-architecture.png) | Original overview inspected, then replaced in this update. The replacement shows single-AZ workers, namespace scope, IP-target traffic, correctly directed scrape/query/log/alert relationships, and the split between manual provisioning and CI delivery. Editable SVG source is added alongside it. |
| [`docs/release-and-rollback-flow.png`](release-and-rollback-flow.png) | Original release overview inspected, then replaced. The replacement includes atomic rollout recovery, explicit validation recovery, first-install uninstall, manual tag selection, and the limits of prior-revision/dev-result verification. Editable SVG source is added alongside it. |

### Incident reports, logs, and screenshots

These files are historical evidence. Their paths, versions, regions, dashboard states, and workflows can differ from today's manifests; the screenshots are not deployment configuration.

| File | Evidence and interpretation |
|---|---|
| [`incidents/incident-01/unbounded-pod-memory-failure.md`](../incidents/incident-01/unbounded-pod-memory-failure.md) | Compares OOM termination and kubelet eviction from separate builds, then contrasts a memory-limited run. Documents the missing-resource baseline and the guardrails added afterward; the two failure mechanisms have different evidence. |
| [`incidents/incident-01/logs/runA.txt`](../incidents/incident-01/logs/runA.txt) | Captures the earlier `ap-south-1` run: roughly 95% node memory, OOMKilled stress Pod after additional pressure, surviving podinfo replicas, and no captured eviction event. The region differs from current Terraform. |
| [`incidents/incident-01/logs/runB.txt`](../incidents/incident-01/logs/runB.txt) | Captures the later `ap-south-2` run: BestEffort stress Pod, memory pressure, explicit Evicted reason/message, 100Mi eviction threshold, and recovery in node usage. Also includes startup/networking events unrelated to the primary failure. |
| [`incidents/incident-02/guardrails-and-monitoring.md`](../incidents/incident-02/guardrails-and-monitoring.md) | Explains how namespace defaults bound the repeated stress workload and why restart metrics now detect it. Distinguishes the raw restart count from Prometheus's windowed increase estimate. |
| [`incidents/incident-02/logs/guardrail-test.txt`](../incidents/incident-02/logs/guardrail-test.txt) | Shows injected 500m/256Mi limits, repeated OOM/CrashLoopBackOff behavior, podinfo still running, and node memory near the same 25% baseline. Supports containment for that captured run. |
| [`incidents/incident-02/grafana-dashboard.png`](../incidents/incident-02/grafana-dashboard.png) | Shows the memory-hog restart staircase/count reaching five while podinfo counts remain zero. The broader namespace series explains why a “podinfo” dashboard can also display the stress workload. |
| [`incidents/incident-02/prometheus-alert.png`](../incidents/incident-02/prometheus-alert.png) | Shows `PodinfoContainerRestarting` firing for the memory-hog stress container, consistent with the namespace-wide query. It is evidence of alert evaluation, not external notification delivery. |
| [`incidents/incident-03/healthy-pods-serving-errors.md`](../incidents/incident-03/healthy-pods-serving-errors.md) | Describes podinfo fault injection while Pods stay Running/Ready, per-replica traffic imbalance, recovery, and limited lifecycle logs. Connection reuse is presented as the explanation of observed distribution; current manifests should be checked separately for actual probes. |
| [`incidents/incident-03/logs/fault-injection.txt`](../incidents/incident-03/logs/fault-injection.txt) | Timestamps load startup, fault status/enable/disable requests, and eventual load-Pod completion. Includes an unsuccessful exec invocation followed by corrected commands; completion alone is not a success-rate assertion. |
| [`incidents/incident-03/grafana-monitoring.png`](../incidents/incident-03/grafana-monitoring.png) | Displays elevated 5xx traffic with flat restart counts and continuing request traffic. Corroborates the distinction between process availability and successful responses. |
| [`incidents/incident-04/node-drain-under-load.md`](../incidents/incident-04/node-drain-under-load.md) | Documents temporary second-node capacity, PDB-limited eviction, replacement pods, and monitoring relocation. Zero interrupted k6 iterations in the excerpt is a progress measure, not a reported zero HTTP failure rate. |
| [`incidents/incident-04/logs/node-drain.txt`](../incidents/incident-04/logs/node-drain.txt) | Records PDB eviction refusals, successful sequential replacement, the original cordoned node, monitoring/controller movement, and continuing k6 iteration counts. Shows why both spare capacity and uncordoning before scale-down matter. |
| [`incidents/incident-05/automated-rollback.md`](../incidents/incident-05/automated-rollback.md) | Correlates the fault-enabled v1.8.0 promotion, successful rollout, failed smoke gate, alerts, rollback to v1.7.1, and roughly 2m39s between recorded Helm revisions. Explicitly distinguishes the historical workflow from later hardening. |
| [`incidents/incident-05/dashboard-before.png`](../incidents/incident-05/dashboard-before.png) | Baseline application dashboard: 100% success, no shown 5xx traffic, v1.7.1, and disabled fault mode in the captured time window. |
| [`incidents/incident-05/dashboard-during.png`](../incidents/incident-05/dashboard-during.png) | Shows success around 0.73%, high 5xx traffic, the v1.8.0 transition, and fault mode enabled while histogram-derived latency remains low. |
| [`incidents/incident-05/dashboard-after.png`](../incidents/incident-05/dashboard-after.png) | Shows return to 100% success and disabled fault mode, with the version/fault timeline preserving the failed-release interval. |
| [`incidents/incident-05/github-actions-rollback.png`](../incidents/incident-05/github-actions-rollback.png) | Shows successful deploy, failed smoke, skipped load, successful recovery step, and a failed overall promotion. The step name belongs to the earlier workflow. |
| [`incidents/incident-05/github-actions-rollback-history.png`](../incidents/incident-05/github-actions-rollback-history.png) | Shows restored Pods and Helm history preserving the failed upgrade and new rollback revision. Confirms that recovery did not erase deployment history. |
| [`incidents/incident-05/prometheus-alert-error-rate.png`](../incidents/incident-05/prometheus-alert-error-rate.png) | Captures `AppHighErrorRate` firing for app-prod at approximately a 0.99 error ratio; does not show an alert-driven rollback action. |
| [`incidents/incident-05/prometheus-alert-fault-mode.png`](../incidents/incident-05/prometheus-alert-fault-mode.png) | Shows the `ALERTS` series for fault-mode alert state across affected pods. Provides a separate configuration signal alongside the HTTP-error metric. |
| [`incidents/incident-05/prometheus-alerts-resolved.png`](../incidents/incident-05/prometheus-alerts-resolved.png) | Shows all four custom application alert rules inactive after recovery in the captured window. |

## Verification for this documentation change

- Existing application suite: **6 tests passed** using the pinned direct dependencies and pytest 8.2.2; transitive dependencies were resolved at review time.
- Static checks: Python syntax, shell syntax, non-template YAML parsing, dashboard JSON parsing, and embedded/standalone dashboard equality.
- Documentation checks: every baseline path represented in this review, local Markdown targets present, SVG XML valid, PNGs rendered and visually inspected, and whitespace errors checked with `git diff --check`.
- No infrastructure apply/destroy, cluster access, deployment, chaos run, or live k6 test was executed. Terraform and Helm CLI validation were not run locally because those executables were not available. The repository's PR workflow defines those checks.

## Maintaining the diagrams

The PNGs embedded in the README are rendered from the adjacent SVGs. The SVGs contain ordinary editable shapes, text, and paths, with no scripts or remote assets. Update both formats together when the implementation changes, then verify labels, arrow directions, resource ownership, and lab constraints against the referenced code. The diagram footer identifies the source snapshot; it is not a claim about the current deployed AWS environment.
