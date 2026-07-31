# Incident 04 — Node Drain Under Load

> **Scenario:** `podinfo`, the sample application running on the cluster, was kept under continuous k6 load while its original worker node was drained for planned maintenance.

This test checked whether the application could remain available while both replicas were moved to another node.

A `PodDisruptionBudget` with `minAvailable: 1` prevented both replicas from being evicted at the same time. Kubernetes waited for a replacement to become available before allowing the second eviction.

---

## Test Setup

The node group normally used one worker node and allowed scaling up to two.

A second node was added before the test so evicted workloads had somewhere to run. Both existing `podinfo` replicas were still on the original node:

```console
krishna@Asus-ROG:~/eks-observable-platform$ kubectl get pods -n manual-managed -o wide
NAME                       READY   STATUS    RESTARTS   AGE   IP           NODE
podinfo-7fc7b45d94-5kkkj   1/1     Running   0          36m   10.0.0.43    ip-10-0-0-133.ap-south-2.compute.internal
podinfo-7fc7b45d94-tgwkd   1/1     Running   0          36m   10.0.0.174   ip-10-0-0-133.ap-south-2.compute.internal
```

A new k6 run was started before the drain:

```console
krishna@Asus-ROG:~/eks-observable-platform$ kubectl delete pod k6-load -n k6-testing
pod "k6-load" deleted from k6-testing namespace

krishna@Asus-ROG:~/eks-observable-platform$ kubectl apply -f k6/k6-job.yaml
pod/k6-load created
```

k6 ran in the separate `k6-testing` namespace on the other worker node, so the load generator itself was not evicted during the drain.

---

## Node Drain

The drain started at 12:06:06 UTC:

```console
krishna@Asus-ROG:~/eks-observable-platform$ date
Fri Jul 31 12:06:06 UTC 2026

krishna@Asus-ROG:~/eks-observable-platform$ kubectl drain ip-10-0-0-133.ap-south-2.compute.internal \
  --ignore-daemonsets \
  --delete-emptydir-data
node/ip-10-0-0-133.ap-south-2.compute.internal cordoned
```

The node was first cordoned so no new workloads could be scheduled on it. Kubernetes then began evicting non-DaemonSet pods.

---

## PodDisruptionBudget in Action

The drain attempted to evict both `podinfo` replicas:

```console
evicting pod manual-managed/podinfo-7fc7b45d94-5kkkj
evicting pod manual-managed/podinfo-7fc7b45d94-tgwkd
```

The PDB allowed the first eviction but blocked the second:

```console
error when evicting pods/"podinfo-7fc7b45d94-tgwkd" -n "manual-managed" \
(will retry after 5s): Cannot evict pod as it would violate the pod's disruption budget.
```

The same refusal appeared again while Kubernetes waited:

```console
evicting pod manual-managed/podinfo-7fc7b45d94-tgwkd
error when evicting pods/"podinfo-7fc7b45d94-tgwkd" -n "manual-managed" \
(will retry after 5s): Cannot evict pod as it would violate the pod's disruption budget.
```

After the first replacement became available on the new node, the second eviction was allowed:

```console
pod/podinfo-7fc7b45d94-5kkkj evicted
evicting pod manual-managed/podinfo-7fc7b45d94-tgwkd
pod/podinfo-7fc7b45d94-tgwkd evicted
node/ip-10-0-0-133.ap-south-2.compute.internal drained
```

CoreDNS showed the same PDB protection during the drain. One DNS pod was temporarily blocked from eviction until another remained available.

---

## After the Drain

Both replacement `podinfo` pods were running on the new node:

```console
krishna@Asus-ROG:~/eks-observable-platform$ kubectl get pods -n manual-managed -o wide
NAME                       READY   STATUS    RESTARTS   AGE     IP           NODE
podinfo-7fc7b45d94-8tbbg   1/1     Running   0          4m9s    10.0.0.165   ip-10-0-0-211.ap-south-2.compute.internal
podinfo-7fc7b45d94-pkqtb   1/1     Running   0          4m20s   10.0.0.163   ip-10-0-0-211.ap-south-2.compute.internal
```

The replacement ages were 11 seconds apart. This matched the drain behaviour: one replica was moved first, then the second.

The original node remained healthy but unavailable for scheduling:

```console
krishna@Asus-ROG:~/eks-observable-platform$ kubectl get nodes
NAME                                        STATUS                     ROLES    AGE     VERSION
ip-10-0-0-133.ap-south-2.compute.internal   Ready,SchedulingDisabled   <none>   5h37m   v1.36.2-eks-bca9cf6
ip-10-0-0-211.ap-south-2.compute.internal   Ready                      <none>   7m17s   v1.36.2-eks-bca9cf6
```

---

## Load Test Result

k6 continued running after the drain:

```console
krishna@Asus-ROG:~/eks-observable-platform$ kubectl logs k6-load -n k6-testing --tail=20
running (06m05.0s), 3/3 VUs, 2824655 complete and 0 interrupted iterations
default   [  41% ] 3 VUs  06m05.0s/15m0s

running (06m06.0s), 3/3 VUs, 2832439 complete and 0 interrupted iterations
default   [  41% ] 3 VUs  06m06.0s/15m0s

running (06m07.0s), 3/3 VUs, 2840617 complete and 0 interrupted iterations
default   [  41% ] 3 VUs  06m07.0s/15m0s
```

During the captured period, k6 completed more than **2.8 million iterations** with **zero interrupted iterations**.

The surviving replica continued serving while the other replica was replaced.

---

## Why the PDB Mattered

The safe drain depended on three parts working together:

| Protection | Role |
|---|---|
| Two application replicas | Kept another pod available during replacement |
| Second worker node | Provided capacity for the replacement pods |
| `PodDisruptionBudget` | Prevented both replicas from being voluntarily evicted together |

Without the PDB, both replicas could have been evicted in the same drain batch. That would create a risk of a short outage while both replacements started.

The PDB changed the drain from a bulk move into a controlled, one-at-a-time migration.

---

## Monitoring Placement

The drain also moved several monitoring components:

```console
evicting pod monitoring/kps-kube-state-metrics-5498c6bd8d-545kr
evicting pod monitoring/kps-grafana-68bf56579d-xpwm4
evicting pod monitoring/loki-0
evicting pod monitoring/alertmanager-kps-kube-prometheus-stack-alertmanager-0
evicting pod monitoring/prometheus-kps-kube-prometheus-stack-prometheus-0
```

The monitoring stack was able to move with the other workloads, but this also showed an important design point: monitoring can be temporarily interrupted when it runs on the same worker node being maintained.

For this project, running everything in one worker group kept the setup simple. In a production environment, observability components can be placed on dedicated nodes, spread across failure domains, and backed by persistent storage when stronger availability is required.

---

## PDB Scope

The PDB protected the application during this planned drain because `kubectl drain` uses voluntary eviction.

A PDB is designed for planned actions such as:

- node drains
- maintenance
- voluntary pod eviction

It does not prevent sudden failures such as a node crash or an OOM termination. Those cases require replicas, resource controls, monitoring, and other recovery mechanisms.

---

## Key Takeaways

- The PDB prevented both `podinfo` replicas from being evicted together.
- A second node was required so replacement pods had somewhere to run.
- k6 continued under load with more than 2.8 million completed and zero interrupted iterations.
- Replicas, spare capacity, and the PDB worked together to keep the application available.
- Monitoring placement should be planned so the observability system remains available during maintenance.
