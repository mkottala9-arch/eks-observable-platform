# Incident 03 — Healthy Pods Serving HTTP 500 Errors

> **Scenario:** `podinfo`, the sample application running on the cluster, stayed `Running` and `Ready` while fault injection caused application requests to return HTTP 500 responses.

This test checked whether application failure would be detected when Kubernetes still considered the pods healthy.

At peak, the service returned roughly **8,500 HTTP 500 responses per second**. Kubernetes health signals correctly showed that the pods and processes were still running, while the application error-rate metric detected that the responses themselves were failing.

---

## Test Setup

`podinfo` was upgraded from `6.7.0` to `6.14.1` because the older version did not provide the required fault-injection endpoint.

The load test used k6 with three virtual users. k6 ran in the separate `k6-testing` namespace so the load generator was not affected by the application namespace limits and did not appear in the `podinfo` restart panels.

The fault was enabled through the running pod:

```text
POST /fault_injection/enable
```

Application requests returned HTTP 500, while `/healthz` and `/readyz` continued to pass.

---

## Baseline

The load test started at 11:31:16 UTC:

```console
krishna@Asus-ROG:~/eks-observable-platform$ date
Fri Jul 31 11:31:16 UTC 2026

krishna@Asus-ROG:~/eks-observable-platform$ kubectl apply -f k6/k6-job.yaml
pod/k6-load created

krishna@Asus-ROG:~/eks-observable-platform$ kubectl get pods -n k6-testing
NAME      READY   STATUS    RESTARTS   AGE
k6-load   1/1     Running   0          7s
```

Both application pods were healthy:

```console
krishna@Asus-ROG:~/eks-observable-platform$ kubectl get pods -n manual-managed
NAME                       READY   STATUS    RESTARTS   AGE
podinfo-7fc7b45d94-5kkkj   1/1     Running   0          3m18s
podinfo-7fc7b45d94-tgwkd   1/1     Running   0          3m17s
```

Fault injection was initially disabled on both pods:

```console
krishna@Asus-ROG:~/eks-observable-platform$ kubectl exec -n manual-managed podinfo-7fc7b45d94-5kkkj -- \
  curl -s http://localhost:9898/fault_injection/status
{
  "fault_injection": "disabled"
}

krishna@Asus-ROG:~/eks-observable-platform$ kubectl exec -n manual-managed podinfo-7fc7b45d94-tgwkd -- \
  curl -s http://localhost:9898/fault_injection/status
{
  "fault_injection": "disabled"
}
```

---

## Fault Injection

### First Pod

Fault injection was enabled on `podinfo-7fc7b45d94-5kkkj` at 11:34:11 UTC:

```console
krishna@Asus-ROG:~/eks-observable-platform$ date
Fri Jul 31 11:34:11 UTC 2026

krishna@Asus-ROG:~/eks-observable-platform$ kubectl exec -n manual-managed podinfo-7fc7b45d94-5kkkj -- \
  curl -X POST http://localhost:9898/fault_injection/enable
{
  "fault_injection": "enabled"
}
```

A partial failure was expected, but the observed error rate remained very low.

### Second Pod

Fault injection was enabled on `podinfo-7fc7b45d94-tgwkd` at 11:41:35 UTC:

```console
krishna@Asus-ROG:~/eks-observable-platform$ date
Fri Jul 31 11:41:35 UTC 2026

krishna@Asus-ROG:~/eks-observable-platform$ kubectl exec -n manual-managed podinfo-7fc7b45d94-tgwkd -- \
  curl -X POST http://localhost:9898/fault_injection/enable
{
  "fault_injection": "enabled"
}
```

Once both pods were faulted, the error rate increased to roughly **8,500 HTTP 500 responses per second**.

### Recovery

The fault was disabled on both pods at 11:45:50 UTC:

```console
krishna@Asus-ROG:~/eks-observable-platform$ date
Fri Jul 31 11:45:50 UTC 2026

krishna@Asus-ROG:~/eks-observable-platform$ kubectl exec -n manual-managed podinfo-7fc7b45d94-5kkkj -- \
  curl -X POST http://localhost:9898/fault_injection/disable
{
  "fault_injection": "disabled"
}

krishna@Asus-ROG:~/eks-observable-platform$ kubectl exec -n manual-managed podinfo-7fc7b45d94-tgwkd -- \
  curl -X POST http://localhost:9898/fault_injection/disable
{
  "fault_injection": "disabled"
}
```

The error rate returned to zero immediately, while request traffic continued.

The k6 job later completed successfully:

```console
krishna@Asus-ROG:~/eks-observable-platform$ kubectl get pods -n k6-testing
NAME      READY   STATUS      RESTARTS   AGE
k6-load   0/1     Completed   0          16m
```

---

## What the Dashboard Showed

Grafana showed:

- both `podinfo` containers at zero restarts
- HTTP 500 responses rising to roughly 8,500 requests per second
- request traffic continuing while the application returned errors
- the error rate dropping to zero after fault injection was disabled

![Grafana showing HTTP 500 errors while pod restarts remain at zero](grafana-monitoring.png)

Kubernetes still reported both pods as healthy because the process remained running and the health endpoints continued to pass.

---

## Finding 1 — Partial Failure Was Masked by Connection Reuse

Faulting one of two pods was expected to produce close to a 50% error rate. Instead, only a small number of errors appeared.

The likely reason was connection reuse. k6 kept its HTTP connections open, so most traffic stayed on the healthy pod instead of being split again for every request.

The first pod was faulty, but it received very little traffic. The failure became fully visible only after both pods were faulted.

Without application monitoring, this partial failure would have been difficult to identify. Kubernetes still showed both pods as healthy, while the error-rate metric showed that one replica was not serving requests correctly.

---

## Finding 2 — Recovery Did Not Immediately Rebalance Traffic

After fault injection was disabled, traffic remained concentrated on one pod.

The existing connections were healthy again, so there was no reason for clients to reconnect. The recovered replica remained mostly idle until new connections were created.

Restarting the load generator redistributed traffic across both pods, confirming that the imbalance was connection-related.

Traffic may stay uneven until clients reconnect or new connections are created.

---

## Observability Result

Loki was queried after the test to check whether the HTTP 500 responses were also recorded in application logs.

The query confirmed that `podinfo` logs lifecycle activity but does not emit one log entry for every request. This was useful because it showed that the logging pipeline was working as expected and that this particular failure belonged in application metrics rather than infrastructure or lifecycle logs.

| Signal | What it showed |
|---|---|
| Kubernetes Events | Pods remained healthy from Kubernetes' perspective |
| Readiness and liveness | The process and health endpoints continued to pass |
| Container restarts | No container crash occurred |
| Loki | Confirmed that no per-request error logs were emitted |
| Application error-rate metric | Detected the HTTP 500 failure immediately |

Each signal had a different purpose. The error-rate metric showed that requests were failing, while Loki provided the application logs available for investigation.

Metrics are useful for showing the size and timing of a problem. When the application writes detailed request or error logs, Loki can add the context that metrics cannot provide, such as the failed operation, error message, request details, or affected component. Together, metrics show what happened and logs help explain why.

---

## Key Takeaways

- A pod can remain `Running` and `Ready` while the application returns HTTP 500 responses.
- Application metrics are needed to detect user-facing failures that Kubernetes health checks cannot see.
- Loki complements metrics by providing detailed error context when the application writes it.
- Connection reuse can hide a failing replica by keeping most traffic on a healthy pod.
- Traffic may remain uneven after recovery until clients create new connections.
