# Incident 03 — Healthy Pods Serving HTTP 500 Errors

> **Scenario:** `podinfo`, the sample application running on the cluster, stayed `Running` and `Ready` while fault injection caused application requests to return HTTP 500 responses.

This test demonstrated how application-level monitoring can detect user-facing failures even when pod status, readiness checks, and restart metrics remain normal.

At peak, the service returned roughly **8,500 HTTP 500 responses per second**. Kubernetes health signals continued to show that the pods and processes were running normally, while the application error-rate metric revealed that the responses themselves were failing.

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

## Finding 2 — Healthy Did Not Mean Traffic Was Reaching the Pod

After fault injection was disabled, both pods were healthy again, but traffic remained concentrated on one replica.

The existing client connections continued using the same pod, so the recovered replica received very little traffic. A manual request to the pod would have succeeded, but it would not have shown whether live application traffic was actually reaching that replica.

Restarting the load generator created new connections and redistributed requests across both pods, confirming that the imbalance was connection-related.

This showed the value of monitoring request rate per replica. Pod health confirms that an application can serve requests, while application metrics confirm whether it is actually receiving and serving traffic.

---

## Observability Result

Loki was queried after the test to check the application logs available during the HTTP 500 failure.

The query confirmed that `podinfo` was sending lifecycle logs through the Loki and Promtail pipeline. For this test, the application error-rate metric provided the main signal because `podinfo` did not emit one log entry for every request.

| Signal | What It Showed |
|---|---|
| Kubernetes Events | The pods remained healthy from Kubernetes' perspective |
| Readiness and liveness | The process and health endpoints continued to pass |
| Container restarts | No container crash occurred |
| Loki | Confirmed the logging pipeline and captured the application lifecycle logs |
| Application error-rate metric | Detected the HTTP 500 responses immediately |

Each signal provided a different part of the incident. Application metrics showed when requests were failing and the scale of the failure, while Loki provided the logs emitted by the application.

When request and error logging is enabled in the application, the same Loki pipeline can collect details such as failed operations, error messages, request information, and affected components. Together, metrics show what happened, while logs help explain why.

---

## Key Takeaways

- A pod can remain `Running` and `Ready` while the application returns HTTP 500 responses.
- Application metrics are needed to detect user-facing failures that Kubernetes health checks cannot see.
- Loki complements metrics by providing detailed error context when the application writes it.
- Connection reuse can hide a failing replica by keeping most traffic on a healthy pod.
- Traffic may remain uneven after recovery until clients create new connections.
