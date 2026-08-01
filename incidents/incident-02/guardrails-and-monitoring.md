# Incident 02 — Guardrails and Monitoring

> **Scenario:** `podinfo`, the sample application running on the cluster, remained healthy while the memory-hog workload from Incident 01 was deployed as a Kubernetes Deployment with namespace guardrails and monitoring enabled. The repeated container restarts were then detected through Grafana and Prometheus alerting.

Incident 02 repeated the same 6 GiB memory test from Incident 01.

This time, the namespace had:

- a `LimitRange`
- a `ResourceQuota`
- Prometheus and Grafana monitoring
- a container restart alert

The failure was contained to one container and detected automatically.

---


## Test Setup

The memory hog ran as a Deployment instead of a one-time pod.

A bare pod with `restartPolicy: Never` terminates once and leaves its restart count at zero. A Deployment restarts the failed container, creating a restart signal that can be monitored.

The manifest intentionally declared no resources. Kubernetes applied the namespace defaults automatically through the `LimitRange`.

---

## Baseline

Before the test, both `podinfo` replicas were healthy:

```console
krishna@Asus-ROG:~/eks-observable-platform$ kubectl get pods -n manual-managed
NAME                       READY   STATUS    RESTARTS   AGE
podinfo-5db49c5bdf-4lhs9   1/1     Running   0          19m
podinfo-5db49c5bdf-bjz49   1/1     Running   0          19m
```

Node memory was 1,810 MiB, or 25%:

```console
krishna@Asus-ROG:~/eks-observable-platform$ kubectl top nodes
NAME                                        CPU(cores)   CPU(%)   MEMORY(bytes)   MEMORY(%)
ip-10-0-0-133.ap-south-2.compute.internal   70m          3%       1810Mi          25%
```

The baseline was higher than Incident 01 because the node also hosted the monitoring stack and AWS Load Balancer Controller.

---

## Guardrail Test

The Deployment was created at 07:36:40 UTC:

```console
krishna@Asus-ROG:~/eks-observable-platform$ date
Fri Jul 31 07:36:40 UTC 2026

krishna@Asus-ROG:~/eks-observable-platform$ kubectl apply -f k8s/chaos/memory-hog-deployment.yaml
deployment.apps/memory-hog created
```

Nine seconds later, the container had already exceeded its memory limit:

```console
krishna@Asus-ROG:~/eks-observable-platform$ kubectl get pods -n manual-managed
NAME                         READY   STATUS      RESTARTS     AGE
memory-hog-f697f9d4d-8rdm2   0/1     OOMKilled   1 (4s ago)   9s
podinfo-5db49c5bdf-4lhs9     1/1     Running     0            20m
podinfo-5db49c5bdf-bjz49     1/1     Running     0            20m
```

The Deployment manifest did not declare resources, but the pod received defaults from the namespace `LimitRange`:

```console
krishna@Asus-ROG:~/eks-observable-platform$ kubectl describe pod -n manual-managed -l app=memory-hog | grep -A6 "Limits\|Requests"
    Limits:
      cpu:     500m
      memory:  256Mi
    Requests:
      cpu:        50m
      memory:     64Mi
```

The container exceeded the injected 256 MiB cgroup limit. The worker node's Linux kernel terminated the process inside the container, but this time it enforced the container's cgroup boundary rather than allowing the workload to consume memory up to the node's physical limit. Kubernetes reported the result as `OOMKilled`.

Node memory remained almost unchanged:

```console
krishna@Asus-ROG:~/eks-observable-platform$ kubectl top nodes
NAME                                        CPU(cores)   CPU(%)   MEMORY(bytes)   MEMORY(%)
ip-10-0-0-133.ap-south-2.compute.internal   62m          3%       1820Mi          25%
```

```text
Before: 1810Mi
After:  1820Mi
Delta:    10Mi
```

Both `podinfo` replicas remained healthy.

---

## Restart Behaviour

The Deployment restarted the failed container and entered `CrashLoopBackOff`:

```console
krishna@Asus-ROG:~/eks-observable-platform$ kubectl get pods -n manual-managed -w
NAME                         READY   STATUS             RESTARTS      AGE
memory-hog-f697f9d4d-8rdm2   0/1     OOMKilled          4 (75s ago)   2m5s
memory-hog-f697f9d4d-8rdm2   0/1     CrashLoopBackOff   4 (88s ago)   3m20s
memory-hog-f697f9d4d-8rdm2   1/1     Running            5 (89s ago)   3m21s
memory-hog-f697f9d4d-8rdm2   0/1     OOMKilled          5 (90s ago)   3m22s
memory-hog-f697f9d4d-8rdm2   0/1     CrashLoopBackOff   5 (76s ago)   4m38s
```

The restart count later remained at five because Kubernetes increased the delay between restart attempts.

A flat restart count during `CrashLoopBackOff` does not mean that the workload has recovered.

---

## Monitoring Result

### Grafana

Grafana showed:

- both `podinfo` containers at zero restarts
- the memory-hog container at five restarts
- a stair-step increase in the restart time series

![Grafana container restart panels](grafana-dashboard.png)

### Prometheus

The `PodinfoContainerRestarting` alert moved to `Firing`.

The rule was:

```promql
increase(kube_pod_container_status_restarts_total{namespace="manual-managed"}[5m]) > 0
```

The alert identified:

```text
pod="memory-hog-f697f9d4d-8rdm2"
container="stress"
namespace="manual-managed"
state="FIRING"
value="4.1168..."
```

![Prometheus restart alert firing](prometheus-alert.png)

Prometheus showed an estimated increase of about `4.12`, while Grafana and `kubectl` showed five restarts.

This was expected. `increase()` estimates the increase over the selected time window and can return a fractional value. The raw restart counter remains the exact count.

---

## Why Monitoring Mattered

Incident 01 showed that a memory failure can develop quickly and may require manual inspection of pod status, node conditions, and Events.

In Incident 02, the memory limit contained the failure before it affected the node, while Prometheus detected the restart automatically and moved the alert to `Firing`.

The monitoring system raised an alert without waiting for manual inspection. The restart alert was the example used in this test, while the same stack can also monitor node, pod, container, and application conditions.

---

## Metric Sources Collected

Prometheus collected metrics from four main sources:

| Source | What it provides |
|---|---|
| `kube-state-metrics` | Kubernetes object state, including pod status, deployments, and restart counters |
| `node-exporter` | Node CPU, memory, filesystem, and network metrics |
| kubelet / cAdvisor | Pod and container CPU, memory, and network usage |
| `podinfo` application metrics | Request rate, response status, and application behaviour |

All four sources were collected. The pre-built dashboards shipped with `kube-prometheus-stack` provided node and container views from `node-exporter` and cAdvisor.

This project's custom dashboards and alert used `kube-state-metrics` and the application's own metrics.


---

## Findings

### The Guardrail Worked

The same 6 GiB allocation that pushed the node to 95% in Incident 01 was stopped at the injected 256 MiB container limit.

| Observation | Incident 01 | Incident 02 |
|---|---:|---:|
| Memory limit | None | 256 MiB, injected |
| Node memory | 541 MiB → 6,760 MiB | 1,810 MiB → 1,820 MiB |
| Failure scope | Node-level memory pressure | One container |
| Result | `OOMKilled` or `Evicted` | `OOMKilled` and restarted |
| Detection | Manual inspection | Grafana and Prometheus |

### The Alert Was Intentionally Namespace-Scoped

The alert was designed to watch all containers in the `manual-managed` namespace, so it correctly fired for the memory-hog Deployment.

This made the rule useful for detecting any restarting workload in the namespace. If monitoring later needs to focus only on selected pods or a specific application, the PromQL query can be narrowed with pod-name or workload-label filters.

### The Restart Alert Was One Example

This incident used container restarts as the test signal because the memory-hog Deployment restarted after each OOM termination.

The alert moved to `Firing` as expected, proving that the monitoring and alerting path worked from metric collection to detection.

Restart monitoring was only one example. The same Prometheus and Alertmanager setup can also be used for node pressure, pod availability, application errors, latency, and other conditions by adding the required queries and alert rules.

---

## Key Takeaways

- The `LimitRange` contained the 6 GiB memory test at the container's 256 MiB limit.
- Prometheus detected the restart automatically while both `podinfo` replicas remained healthy.
- The restart alert proved the complete monitoring path from metric collection to alerting.
- The stack collected node, Kubernetes, container, and application metrics, while the custom views focused on restart and application signals.
- The same monitoring stack can be extended with more dashboards and alerts for production workloads.
