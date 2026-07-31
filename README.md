# EKS Observable Platform

A hands-on Amazon EKS project for learning how Kubernetes behaves during memory pressure, application failures, and planned node maintenance.

The platform runs the `podinfo` sample application with resource guardrails, load testing, metrics, logs, dashboards, and alerting. Four controlled incidents were used to verify how the cluster behaves when something goes wrong.

## What This Project Covers

- EKS infrastructure provisioned with Terraform
- Two-replica `podinfo` application exposed through an AWS Application Load Balancer using the AWS Load Balancer Controller
- CPU and memory requests and limits
- Namespace `LimitRange` and `ResourceQuota`
- `PodDisruptionBudget` for planned maintenance
- Prometheus, Grafana, Alertmanager, Loki, and Promtail
- Application metrics collected through a `ServiceMonitor`
- k6 load testing from a separate namespace
- Failure testing with memory stress, HTTP 500 injection, and node drain

## Architecture

![EKS Observable Platform architecture](docs/eks-observable-platform-architecture.png)


Terraform manages the AWS network, IAM roles, EKS cluster, and managed node group. Kubernetes manifests and Helm manage the application, policies, ingress controller, and observability components.

## Platform Design

| Component | Configuration |
|---|---|
| AWS region | `ap-south-2` |
| VPC | `10.0.0.0/16` |
| Subnets | Two public subnets across two Availability Zones |
| EKS node group | `m7i-flex.large`, desired `1`, maximum `2` |
| Application | `podinfo:6.14.1`, two replicas |
| Application namespace | `manual-managed` |
| Load-test namespace | `k6-testing` |
| Ingress | AWS Load Balancer Controller, IP target mode |
| Monitoring | Prometheus, Grafana, Alertmanager, Loki, Promtail |
| Load testing | k6, three virtual users |

The second node is used for the planned node-drain test. The default cluster remains small to keep the lab cost controlled.

## Resource Guardrails

The application declares:

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

- A `LimitRange` that injects default requests and limits
- A maximum container memory limit of `512Mi`
- A `ResourceQuota` that caps total namespace consumption
- A `PodDisruptionBudget` with `minAvailable: 1`

These controls were added and tested after the first memory-pressure incident.

## Observability

Prometheus collects metrics from four main sources:

| Source | Purpose |
|---|---|
| `kube-state-metrics` | Kubernetes object state, pod status, deployments, and restart counters |
| `node-exporter` | Node CPU, memory, filesystem, and network metrics |
| kubelet / cAdvisor | Pod and container resource metrics |
| `podinfo` metrics | Request rate, response status, and application latency |

All four sources are collected. The pre-built dashboards shipped with `kube-prometheus-stack` provide node and container views from `node-exporter` and cAdvisor.

The custom dashboards and alert in this project use `kube-state-metrics` and the application's own metrics.

Loki and Promtail collect container logs. Metrics show when and how much a service is failing, while logs can provide the detailed context needed to understand why.

### Monitoring Screenshots

**Grafana — container restarts and application metrics**

![Grafana dashboard showing pod restarts and application metrics](incidents/incident-02/grafana-dashboard.png)

**Prometheus — restart alert firing**

![Prometheus alert firing for the memory-hog container](incidents/incident-02/prometheus-alert.png)

**Grafana — application error monitoring during fault injection**

![Grafana dashboard showing HTTP 500 errors during fault injection](incidents/incident-03/grafana-monitoring.png)

## Incident Reports

| Incident | Test | Result |
|---|---|---|
| [01 — Unbounded Pod Memory Failure](incidents/incident-01/unbounded-pod-memory-failure.md) | A pod attempted to allocate 6 GiB without requests or limits | Produced both `OOMKilled` and kubelet `Evicted` outcomes across two runs |
| [02 — Guardrails and Monitoring](incidents/incident-02/guardrails-and-monitoring.md) | The same memory test was repeated with namespace policies and alerting | Failure stayed inside one container and the restart alert moved to `Firing` |
| [03 — Healthy Pods Serving Errors](incidents/incident-03/healthy-pods-serving-errors.md) | Fault injection returned HTTP 500 while probes remained healthy | Application metrics detected the failure while Kubernetes still showed `Running` and `Ready` |
| [04 — Node Drain Under Load](incidents/incident-04/node-drain-under-load.md) | The original node was drained while k6 traffic continued | The PDB moved replicas one at a time and k6 recorded zero interrupted iterations |

Together, the incidents show why infrastructure health, Kubernetes state, application metrics, logs, alerts, and workload policies are all needed.

## Repository Structure

```text
.
├── README.md
├── backend.tf
├── docs/
│   ├── eks-observable-platform-architecture.png
│   └── runbook.md
├── eks.tf
├── incidents/
│   ├── incident-01/
│   │   ├── logs/
│   │   │   ├── runA.txt
│   │   │   └── runB.txt
│   │   └── unbounded-pod-memory-failure.md
│   ├── incident-02/
│   │   ├── grafana-dashboard.png
│   │   ├── guardrails-and-monitoring.md
│   │   ├── logs/
│   │   │   └── guardrail-test.txt
│   │   └── prometheus-alert.png
│   ├── incident-03/
│   │   ├── grafana-monitoring.png
│   │   ├── healthy-pods-serving-errors.md
│   │   └── logs/
│   │       └── fault-injection.txt
│   └── incident-04/
│       ├── logs/
│       │   └── node-drain.txt
│       └── node-drain-under-load.md
├── k6/
│   ├── k6-job.yaml
│   └── load-test.js
├── k8s/
│   ├── chaos/
│   │   ├── memory-hog-deployment.yaml
│   │   ├── memory-hog-limited.yaml
│   │   └── memory-hog-unbounded.yaml
│   └── manual/
│       ├── deployment-v1-no-limits.yaml
│       ├── deployment-v2-with-limits.yaml
│       ├── ingress.yaml
│       ├── limitrange.yaml
│       ├── pdb.yaml
│       ├── resourcequota.yaml
│       └── service.yaml
├── main.tf
├── observability/
│   ├── grafana-dashboards/
│   │   └── podinfo-dashboard.json
│   ├── kube-prom-stack-values.yaml
│   ├── loki-values.yaml
│   ├── podinfo-alert-rules.yaml
│   └── podinfo-servicemonitor.yaml
└── vpc.tf
```

## Prerequisites

- AWS account and configured AWS CLI credentials
- Terraform `1.10+`
- `kubectl`
- Helm
- `eksctl`





## Installation and Operations

The complete installation, rebuild, ingress, load-testing, and teardown steps are documented in [docs/runbook.md](docs/runbook.md).

## Lab Notes

- Worker nodes use public subnets to avoid NAT Gateway cost.
- The node group normally runs one node and temporarily scales to two for the drain test.
- Loki persistence is disabled.
- Grafana has no persistent volume, so the custom dashboard is imported again after a rebuild.
- This is a learning platform, not a production reference architecture.
