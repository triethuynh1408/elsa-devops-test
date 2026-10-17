# Part 3: Troubleshooting `broken-app.yaml`

**Result:** `troubleshoot/verify.sh` prints `PASS` after `kubectl apply -f troubleshoot/fixed-app.yaml`. This holds on a clean namespace, on top of the broken manifests, and on a re-run. The `default-deny` NetworkPolicy and all node labels and taints are untouched.

Run it: `./scripts/30-troubleshoot.sh`

## Approach

The failures were **layered**: each one hid the next. A pod that can't be scheduled never pulls its image, so you can't see a bad image tag. A pod that can't mount its volume never starts, so you can't see a bad probe. Reading the YAML alone you can spot most issues, but you can't prove which one is actually blocking. So I worked like an incident:

1. Take the symptom from `verify.sh` and `kubectl get`.
2. Read events (`kubectl describe`, `kubectl get events`).
3. Form a hypothesis and confirm it with a targeted command.
4. Fix only that, live (`kubectl patch`), and see what surfaces next.
5. Once everything worked, write the fixes into `fixed-app.yaml` and re-test from scratch.

Starting point:

```console
$ kubectl apply -f troubleshoot/broken-app.yaml && ./troubleshoot/verify.sh
[3/7] Deployment 'web' must be fully rolled out...
error: timed out waiting for the condition
FAIL: deployment/web is not ready

$ kubectl get pods -n troubleshoot -o wide
ai-inference-77cfc6f99b-q69zx   0/1   Pending   <none>
web-5c8d87f7d8-2j29q            0/1   Pending   <none>
web-5c8d87f7d8-69spl            0/1   Pending   <none>

$ kubectl get events -n troubleshoot --sort-by=.lastTimestamp
pod/ai-inference-...  0/5 nodes are available: 2 node(s) had untolerated taint(s),
                      3 node(s) didn't match Pod's node affinity/selector.
pod/web-...           0/5 nodes are available: 2 node(s) had untolerated taint(s),
                      3 Insufficient memory.
```

(The "2 untolerated taints" are the GPU node and the control-plane node. For `web`, those are expected and correct.)

## Summary

| # | Workload | Layer | Symptom | Root cause | Fix |
|---|---|---|---|---|---|
| 1 | web | Scheduling | Pending, `Insufficient memory` | Requests 16Gi; nodes have ~7.6Gi allocatable | 32Mi request / 128Mi limit |
| 2a | ai-inference | Scheduling | Pending, `didn't match node selector` | `nodeSelector: node-type: gpu`; real label is `acme.io/node-type` | Correct label key |
| 2b | ai-inference | Scheduling | (hidden behind 2a) untolerated taint | No toleration for `nvidia.com/gpu:NoSchedule` | Add toleration |
| 3 | web | Volume mount | Stuck `ContainerCreating`, `FailedMount` | Volume references ConfigMap `web-conf`; it's `web-config` | Correct name |
| 4 | web | Image | `ErrImagePull` / `ImagePullBackOff` | Tag `nginx:1.25.99` doesn't exist | `nginx:1.25.5` |
| 5 | web | Probes | Running but 0/1, restarting | Probes hit 8080; nginx listens on 80 | Probes on named port `http` (80) |
| 6 | web-svc | Service | No endpoints | Selector `app: webapp`; pods are `app: web` | `app: web` |
| 7 | web-svc | Service | (hidden behind 6) traffic to the wrong port | `targetPort: 8080` | `targetPort: http` |
| 8 | namespace | Network | Smoke test: `Couldn't connect` | `default-deny` blocks all ingress + egress, including DNS; no allow rules | 3 least-privilege allow policies |

## Issue details

### 1. `web` requests 16Gi of memory

- **Symptom:** both `web` pods Pending. Event: `3 Insufficient memory`.
- **Diagnosis:**
  ```console
  $ kubectl get nodes -o custom-columns=NODE:.metadata.name,ALLOC_MEM:.status.allocatable.memory
  k3d-elsa-agent-0    8024472Ki      # ~7.6Gi, the same on every node
  $ kubectl get deploy web -n troubleshoot -o jsonpath='{.spec.template.spec.containers[0].resources}'
  {"limits":{"cpu":"500m","memory":"16Gi"},"requests":{"cpu":"100m","memory":"16Gi"}}
  ```
- **Root cause:** the scheduler places pods by **requests**, not actual usage. A 16Gi request can't fit on any node. A static nginx needs a few MB, so this looks like a typo (`16Mi` → `16Gi`) or a copy-paste from another service.
- **Fix:** `requests.memory: 32Mi`, `limits.memory: 128Mi`. This leaves headroom for nginx's per-CPU worker processes, which run as `worker_processes auto`.

### 2a + 2b. `ai-inference` can't reach the GPU node

- **Symptom:** Pending. Event: `3 node(s) didn't match Pod's node affinity/selector`.
- **Diagnosis:**
  ```console
  $ kubectl get deploy ai-inference -n troubleshoot -o jsonpath='{.spec.template.spec.nodeSelector} {.spec.template.spec.tolerations}'
  {"node-type":"gpu"}
  $ kubectl get nodes -l node-type=gpu
  No resources found
  $ kubectl get nodes -l acme.io/node-type=gpu
  k3d-elsa-agent-3
  $ kubectl get node k3d-elsa-agent-3 -o jsonpath='{.spec.taints}'
  [{"effect":"NoSchedule","key":"nvidia.com/gpu","value":"true"}]
  ```
- **Root cause:** two independent problems.
  - **2a:** the selector uses the wrong label key. The real key carries the `acme.io/` prefix.
  - **2b:** even with the right selector, the GPU node is tainted and the pod has no toleration. 2a hides 2b: the scheduler rejects the node on the selector before it reports the taint.
- **Fix:** `nodeSelector: {acme.io/node-type: gpu}` plus a toleration `nvidia.com/gpu`, `operator: Exists`, `effect: NoSchedule`.
  - A **toleration** only *permits* scheduling on the tainted node. The **nodeSelector** is what *forces* the pod there. You need both.
  - Removing the taint is not allowed. It would also let any workload land on an expensive GPU node.

### 3. ConfigMap name mismatch

- **Symptom:** after fixing #1, the new pod sits in `ContainerCreating` with no image or probe errors.
- **Diagnosis:**
  ```console
  $ kubectl describe pod -n troubleshoot web-fbbbb75d4-j6qtg | sed -n '/Events:/,$p'
  Warning  FailedMount  kubelet  MountVolume.SetUp failed for volume "html" : configmap "web-conf" not found
  $ kubectl get configmap -n troubleshoot
  web-config
  ```
- **Root cause:** the volume references `web-conf`; the ConfigMap is `web-config`. The kubelet mounts volumes **before** pulling the image, so this blocks pod start without any image error.
- **Fix:** `configMap.name: web-config`.

### 4. Non-existent image tag

- **Symptom:** `ErrImagePull`, then `ImagePullBackOff`.
- **Diagnosis:**
  ```console
  $ kubectl get events -n troubleshoot | grep -i pull
  Failed to pull image "nginx:1.25.99": ... docker.io/library/nginx:1.25.99: not found
  $ curl -s -o /dev/null -w '%{http_code}' https://hub.docker.com/v2/repositories/library/nginx/tags/1.25.99   # 404
  $ curl -s -o /dev/null -w '%{http_code}' https://hub.docker.com/v2/repositories/library/nginx/tags/1.25.5    # 200
  ```
- **Root cause:** the tag doesn't exist. The 1.25 line ended at 1.25.5.
- **Fix:** `nginx:1.25.5`, the smallest change that keeps the intended version line. A follow-up outside this incident: 1.25 is end-of-life, so move to a supported line and pin by digest.

### 5. Probes on the wrong port

- **Symptom:** the pod is `Running` but `0/1` Ready, with restarts climbing.
- **Diagnosis:**
  ```console
  $ kubectl describe pod -n troubleshoot web-7bd5794f89-qdt85 | sed -n '/Events:/,$p'
  Liveness probe failed: Get "http://10.42.1.10:8080/": connect: connection refused
  Readiness probe failed: Get "http://10.42.1.10:8080/": connect: connection refused
  Container nginx failed liveness probe, will be restarted
  $ kubectl exec -n troubleshoot web-7bd5794f89-qdt85 -- sh -c 'grep -h listen /etc/nginx/conf.d/*.conf'
  listen       80;
  ```
- **Root cause:** both probes target 8080. nginx listens on 80 (and `containerPort` already said 80). A failing liveness probe gets the container killed. A failing readiness probe keeps it out of the Service.
- **Fix:** name the container port (`http: 80`) and point both probes at the name, so the port is defined in one place.

### 6 + 7. Service selector and targetPort

- **Symptom:** `web` is 2/2 Ready, but the Service has no endpoints.
- **Diagnosis:**
  ```console
  $ kubectl get endpoints web-svc -n troubleshoot
  NAME      ENDPOINTS   AGE
  web-svc   <none>      4m39s
  $ kubectl get svc web-svc -n troubleshoot -o jsonpath='{.spec.selector} {.spec.ports[0].targetPort}'
  {"app":"webapp"} 8080
  $ kubectl get pods -n troubleshoot -l app=webapp
  No resources found
  ```
- **Root cause:**
  - **#6:** the selector `app: webapp` matches no pods; they are labelled `app: web`.
  - **#7:** `targetPort: 8080` would send traffic to a closed port even after #6 is fixed. `verify.sh` step 6 only checks that endpoints *exist*, so #7 would only surface in the step-7 smoke test.
- **Fix:** `selector: {app: web}`, `targetPort: http`.

### 8. default-deny with no allow rules

- **Symptom:** the smoke job fails:
  ```console
  $ kubectl logs -n troubleshoot job/smoke-test
  curl: (7) Failed to connect to web-svc.troubleshoot.svc.cluster.local port 80 after 0 ms: Couldn't connect to server
  ```
- **Diagnosis:** the policy denies Ingress and Egress for every pod (`podSelector: {}`). Curl's error mentioned only the connection, so I checked whether DNS was blocked too. I used a debug pod with the smoke job's label, so the same policies apply to it:
  ```console
  $ kubectl run netdebug -n troubleshoot --image=busybox:1.36 --labels=app=smoke-client --restart=Never -- sleep 600
  $ kubectl exec -n troubleshoot netdebug -- nslookup web-svc.troubleshoot.svc.cluster.local
  nslookup: write to '10.43.0.10': Connection refused        # DNS blocked as well
  $ kubectl exec -n troubleshoot netdebug -- wget -qO- -T 3 http://10.42.2.8/
  wget: can't connect to remote host (10.42.2.8): Connection refused   # pod-to-pod blocked
  $ kubectl get svc kube-dns -n kube-system -o jsonpath='{range .spec.ports[*]}{.port}->{.targetPort}/{.protocol} {end}'
  53->53/UDP 53->53/TCP 9153->9153/TCP
  ```
  The k3s policy controller (kube-router) **rejects** packets rather than dropping them. That's why failures are instant ("after 0 ms") instead of timing out.
- **Root cause:** the `smoke-client` → `web` path needs three things, and all three were denied:
  1. Egress from the client to CoreDNS (DNS lookup).
  2. Egress from the client to the web pods.
  3. Ingress to the web pods from the client.
- **Fix:** keep `default-deny` and add three narrow policies:
  - **`allow-smoke-client-dns`:** `app=smoke-client` → pods `k8s-app=kube-dns` **in** `kube-system`, UDP+TCP 53 only. `namespaceSelector` and `podSelector` sit in the same `to` item, so they are ANDed.
  - **`allow-smoke-client-to-web`:** `app=smoke-client` → `app=web`, TCP 80.
  - **`allow-web-from-smoke-client`:** `app=web` accepts from `app=smoke-client`, TCP 80.

  Ports are the **pod** ports (80, 53), not Service ports, because policies are evaluated after the Service's DNAT. Kubelet probes still work: they come from the node, which k3s allows.

## Verification

```console
$ ./scripts/30-troubleshoot.sh          # clean namespace, fixed-over-broken, and re-run: all PASS
...
[7/7] In-cluster smoke test through the Service...
PASS
ai-inference-68c464595-btlcc   1/1   Running     k3d-elsa-agent-3   # the GPU node
web-857f588dff-lvdmf           1/1   Running     k3d-elsa-agent-2
web-857f588dff-zzg9x           1/1   Running     k3d-elsa-agent-1
```

Least privilege was checked in both directions with throwaway busybox pods:

| From | To | Result |
|---|---|---|
| `app=smoke-client` | `web-svc:80` | ALLOWED |
| `app=smoke-client` | internet `1.1.1.1:80` | BLOCKED |
| `app=smoke-client` | `quote-api.quote` (another namespace) | BLOCKED |
| unlabelled pod | web pod `:80` | BLOCKED |

## Notes on the provided files

- **`verify.sh` step 6** reads the `v1 Endpoints` API, which is deprecated since 1.33 (`kubectl` prints a warning). It still works, so I left it as is. EndpointSlices are the replacement.
- **`verify.sh` step 5** reads `.items[0]` of the `ai-inference` pods. Right after a rollout, a terminating old pod could be `items[0]`. That's a potential flake, and `30-troubleshoot.sh` waits for the rollouts first.

## How I'd prevent these in a real pipeline

- **Schema and policy checks in CI:** `kubeconform`, plus Kyverno/OPA rules such as "requests below X", "probe port must be a declared containerPort", and "Service selector must match a workload in the same chart".
- **Image existence check before merge:** `crane manifest` / `docker buildx imagetools inspect`, and pin images by digest.
- **Template ports by name:** named ports remove a whole class of bugs (#5, #7).
- **Ship NetworkPolicies with the app, not the namespace.** Each chart declares its own ingress and egress needs, including DNS, so default-deny stops being a surprise.
