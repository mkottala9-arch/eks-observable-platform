# Incident 01 — Unbounded Pod Memory Failure

> **Scenario:** `podinfo`, the sample application running on the cluster, had two replicas in the `manual-managed` namespace. A memory stress pod was then deployed on the same single-node EKS cluster without CPU or memory requests and limits.

The test was performed on two separate cluster builds. The same configuration produced two different outcomes:

- **Run A:** container reported as `OOMKilled`
- **Run B:** pod evicted by kubelet

---

## Test Setup

The first pod attempted to allocate **6 GiB**:

```console
krishna@Asus-ROG:~/eks-observable-platform$ kubectl run memory-hog \
  -n manual-managed \
  --restart=Never \
  --image=polinux/stress \
  -- stress --vm 1 --vm-bytes 6G --vm-hang 300
pod/memory-hog created
```

A second pod then attempted to allocate another **1,200 MiB**:

```console
krishna@Asus-ROG:~/eks-observable-platform$ kubectl run memory-hog-2 \
  -n manual-managed \
  --restart=Never \
  --image=polinux/stress \
  -- stress --vm 1 --vm-bytes 1200M --vm-hang 300
pod/memory-hog-2 created
```

Neither pod declared resource requests or limits, so both received the `BestEffort` QoS class.

---

## Run A — OOMKilled

### Baseline

```console
krishna@Asus-ROG:~/eks-observable-platform$ kubectl top pods -n manual-managed
NAME                       CPU(cores)   MEMORY(bytes)
podinfo-647cb9f8f8-2fsks   1m           14Mi
podinfo-647cb9f8f8-vs9rh   1m           12Mi

krishna@Asus-ROG:~/eks-observable-platform$ kubectl top nodes
NAME                                        CPU(cores)   CPU(%)   MEMORY(bytes)   MEMORY(%)
ip-10-0-0-158.ap-south-1.compute.internal   23m          1%       541Mi           7%
```

### Peak Memory

After the 6 GiB pod started:

```console
krishna@Asus-ROG:~/eks-observable-platform$ kubectl top pods -n manual-managed
NAME                       CPU(cores)   MEMORY(bytes)
memory-hog                 0m           6156Mi
podinfo-647cb9f8f8-2fsks   0m           13Mi
podinfo-647cb9f8f8-vs9rh   1m           12Mi

krishna@Asus-ROG:~/eks-observable-platform$ kubectl top nodes
NAME                                        CPU(cores)   CPU(%)   MEMORY(bytes)   MEMORY(%)
ip-10-0-0-158.ap-south-1.compute.internal   28m          1%       6760Mi          95%

krishna@Asus-ROG:~/eks-observable-platform$ kubectl get pods -n manual-managed
NAME                       READY   STATUS    RESTARTS   AGE
memory-hog                 1/1     Running   0          61s
podinfo-647cb9f8f8-2fsks   1/1     Running   0          10m
podinfo-647cb9f8f8-vs9rh   1/1     Running   0          10m
```

The node still reported:

```console
krishna@Asus-ROG:~/eks-observable-platform$ kubectl describe node ip-10-0-0-158.ap-south-1.compute.internal | grep -A8 "Conditions:"
Conditions:
  Type             Status  Reason                       Message
  ----             ------  ------                       -------
  MemoryPressure   False   KubeletHasSufficientMemory   kubelet has sufficient memory available
  DiskPressure     False   KubeletHasNoDiskPressure     kubelet has no disk pressure
  PIDPressure      False   KubeletHasSufficientPID      kubelet has sufficient PID available
  Ready            True    KubeletReady                 kubelet is posting ready status
```

At 95% reported usage, `MemoryPressure` was still `False`. This was not a contradiction: kubelet uses its `memory.available` signal rather than the percentage shown by `kubectl top`. The eviction threshold had not been crossed when the condition was captured.

### Failure

After the second pod started:

```console
krishna@Asus-ROG:~/eks-observable-platform$ kubectl get pods -n manual-managed -w
NAME                       READY   STATUS      RESTARTS   AGE
memory-hog                 0/1     OOMKilled   0          3m14s
memory-hog-2               1/1     Running     0          7s
podinfo-647cb9f8f8-2fsks   1/1     Running     0          12m
podinfo-647cb9f8f8-vs9rh   1/1     Running     0          12m
```

Both `podinfo` replicas remained `Running`.

The Event log contained normal scheduling and startup events, but no OOM or eviction warning:

```console
krishna@Asus-ROG:~/eks-observable-platform$ kubectl get events -n manual-managed --sort-by='.lastTimestamp' | tail -10
LAST SEEN   TYPE     REASON      OBJECT             MESSAGE
4m32s       Normal   Scheduled   pod/memory-hog     Successfully assigned manual-managed/memory-hog to ip-10-0-0-158.ap-south-1.compute.internal
4m28s       Normal   Pulled      pod/memory-hog     Successfully pulled image "polinux/stress"
4m28s       Normal   Created     pod/memory-hog     Container created
4m28s       Normal   Started     pod/memory-hog     Container started
86s         Normal   Scheduled   pod/memory-hog-2   Successfully assigned manual-managed/memory-hog-2 to ip-10-0-0-158.ap-south-1.compute.internal
84s         Normal   Pulled      pod/memory-hog-2   Successfully pulled image "polinux/stress"
84s         Normal   Created     pod/memory-hog-2   Container created
84s         Normal   Started     pod/memory-hog-2   Container started
```

The failure was visible mainly through pod status.

After the kill:

```console
krishna@Asus-ROG:~/eks-observable-platform$ kubectl top nodes
NAME                                        CPU(cores)   CPU(%)   MEMORY(bytes)   MEMORY(%)
ip-10-0-0-158.ap-south-1.compute.internal   21m          1%       1544Mi          21%
```

---

## Run B — Evicted

The same test was repeated on another cluster build. This node also hosted the monitoring stack, so the baseline was higher.

### Baseline

```console
krishna@Asus-ROG:~/eks-observable-platform$ kubectl top nodes
NAME                                        CPU(cores)   CPU(%)   MEMORY(bytes)   MEMORY(%)
ip-10-0-0-180.ap-south-2.compute.internal   60m          3%       1343Mi          18%

krishna@Asus-ROG:~/eks-observable-platform$ kubectl top pods -n manual-managed
NAME                       CPU(cores)   MEMORY(bytes)
podinfo-7fc7b45d94-7z4cc   0m           16Mi
podinfo-7fc7b45d94-cgrkt   1m           16Mi
```

### Peak Memory

```console
krishna@Asus-ROG:~/eks-observable-platform$ kubectl apply -f k8s/chaos/memory-hog-unbounded.yaml
pod/memory-hog-unbounded created

krishna@Asus-ROG:~/eks-observable-platform$ kubectl top pods -n manual-managed
NAME                       CPU(cores)   MEMORY(bytes)
memory-hog-unbounded       0m           6156Mi
podinfo-7fc7b45d94-7z4cc   0m           18Mi
podinfo-7fc7b45d94-cgrkt   1m           16Mi

krishna@Asus-ROG:~/eks-observable-platform$ kubectl top nodes
NAME                                        CPU(cores)   CPU(%)   MEMORY(bytes)   MEMORY(%)
ip-10-0-0-180.ap-south-2.compute.internal   78m          4%       7279Mi          102%
```

### Eviction

After the second memory-hogging pod started, the node entered memory pressure:

```console
krishna@Asus-ROG:~/eks-observable-platform$ kubectl describe node ip-10-0-0-180.ap-south-2.compute.internal | grep -A8 "Conditions:"
Conditions:
  Type             Status  Reason                         Message
  ----             ------  ------                         -------
  MemoryPressure   True    KubeletHasInsufficientMemory   kubelet has insufficient memory available
  DiskPressure     False   KubeletHasNoDiskPressure       kubelet has no disk pressure
  PIDPressure      False   KubeletHasSufficientPID        kubelet has sufficient PID available
  Ready            True    KubeletReady                   kubelet is posting ready status
```

This time, kubelet evicted the original pod:

```console
krishna@Asus-ROG:~/eks-observable-platform$ kubectl describe pod memory-hog-unbounded -n manual-managed
Name:       memory-hog-unbounded
Namespace:  manual-managed
Status:     Failed
Reason:     Evicted
Message:    The node was low on resource: memory. Threshold quantity: 100Mi,
            available: 312Ki. Container stress was using 6304044Ki,
            request is 0, has larger consumption of memory.
QoS Class:  BestEffort
```

The Event log recorded:

```console
krishna@Asus-ROG:~/eks-observable-platform$ kubectl get events -n manual-managed --sort-by='.lastTimestamp' | tail -12
LAST SEEN   TYPE      REASON      OBJECT                       MESSAGE
2m38s       Normal    Scheduled   pod/memory-hog-2             Successfully assigned manual-managed/memory-hog-2 to ip-10-0-0-180.ap-south-2.compute.internal
2m35s       Normal    Started     pod/memory-hog-2             Container started
2m31s       Warning   Evicted     pod/memory-hog-unbounded     The node was low on resource: memory. Threshold quantity: 100Mi, available: 312Ki. Container stress was using 6304044Ki, request is 0, has larger consumption of memory.
2m31s       Normal    Killing     pod/memory-hog-unbounded     Stopping container stress
```

After eviction:

```console
krishna@Asus-ROG:~/eks-observable-platform$ kubectl top nodes
NAME                                        CPU(cores)   CPU(%)   MEMORY(bytes)   MEMORY(%)
ip-10-0-0-180.ap-south-2.compute.internal   66m          3%       2326Mi          32%
```

---

## Comparison

| Observation | Run A | Run B |
|---|---:|---:|
| Peak node memory | 6,760 MiB / 95% | 7,279 MiB / 102% |
| `MemoryPressure` | `False` | `True` |
| Final pod state | `OOMKilled` | `Evicted` |
| Kubernetes Event | No OOM Event | Eviction Event |

The different outcomes were most likely caused by timing.

Kubelet checks eviction thresholds at regular intervals. In Run A, the container was reported as `OOMKilled` before kubelet recorded memory pressure or an eviction. In Run B, the node remained under pressure long enough for kubelet to detect that available memory had fallen below its **100 MiB** threshold and evict the pod.

The same unsafe workload can therefore leave different evidence depending on when node pressure is detected.

---

## Limited Test

The same 6 GiB workload was tested again with:

```yaml
resources:
  requests:
    memory: 256Mi
  limits:
    memory: 512Mi
```

```console
krishna@Asus-ROG:~/eks-observable-platform$ kubectl get pods -n manual-managed -w
NAME                 READY   STATUS              RESTARTS   AGE
memory-hog-limited   0/1     Pending             0          0s
memory-hog-limited   0/1     ContainerCreating   0          0s
memory-hog-limited   1/1     Running             0          4s
memory-hog-limited   0/1     OOMKilled           0          5s

krishna@Asus-ROG:~/eks-observable-platform$ kubectl describe pod memory-hog-limited -n manual-managed
State:          Terminated
  Reason:       OOMKilled
  Exit Code:    137
Limits:
  memory:       512Mi
Requests:
  memory:       256Mi
QoS Class:      Burstable
```

Node memory remained near **7%**:

```console
Before: 516Mi / 7%
After:  499Mi / 7%
```

The memory limit kept the failure inside the container instead of allowing the workload to consume most of the node.

---

## Root Cause

The pod had no resource requests or limits.

- **No request:** the scheduler had no declared memory requirement to consider.
- **No limit:** the container had no configured memory ceiling.
- **BestEffort QoS:** the pod became a likely eviction target during node memory pressure.

---

## Changes Made

- Added CPU and memory requests and limits to `podinfo`
- Added a namespace `LimitRange`
- Added a `ResourceQuota`
- Installed Prometheus, Grafana, Loki, Alertmanager, kube-state-metrics, and node-exporter
- Added monitoring for container restarts and workload failures

---

## Key Takeaways

- Requests help Kubernetes make better scheduling decisions.
- Limits reduce the blast radius of excessive memory usage.
- Kubelet eviction and OOM termination can produce different evidence.
- Pod status and Kubernetes Events should both be checked during memory-related failures.
- Prevention is more reliable than waiting for node-level protection.

