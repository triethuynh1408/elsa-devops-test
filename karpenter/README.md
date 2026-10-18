# Part 5a: Karpenter for GPU inference

Files: `gpu-ec2nodeclass.yaml` (node class), `gpu-nodepools.yaml` (spot + on-demand pools), `example-inference-deployment.yaml` (how a workload opts in).

**API:** Karpenter **v1.15.0**, using `karpenter.sh/v1` and `karpenter.k8s.aws/v1`. Both were checked against the CRDs of that release, not from memory. `v1beta1` has been removed, and so has its `WhenUnderutilized` policy.

**Validate:** `./scripts/51-validate-karpenter.sh`. It installs the pinned CRDs, schemas only, into the local cluster, then runs a server-side dry run, so the OpenAPI schema and the CRDs' CEL rules are both enforced. Negative checks:
- `karpenter.sh/v1beta1` → `no matches for kind`
- `WhenUnderutilized` → `Unsupported value`
- a budget `schedule` without `duration` → rejected by a CEL rule

## Design

| Requirement | How |
|---|---|
| Spot preferred, on-demand fallback | Two NodePools: `gpu-spot` (weight 100) and `gpu-on-demand` (weight 10). Karpenter uses the highest-weight pool that fits. When spot GPU capacity is unavailable, it falls back. Separate pools give **separate spend caps** (on-demand capped at 8 GPUs) and separate disruption rules. |
| Proper taint | `nvidia.com/gpu=true:NoSchedule` and label `acme.io/node-type=gpu`, the same as the nodes in Part 3. Workloads need the toleration *and* the nodeSelector. |
| Consolidation that won't kill inference mid-request | `consolidationPolicy: WhenEmpty` (never repack a busy GPU node: that means a cold start plus aborted requests), `consolidateAfter: 15m`, and a budget of at most 1 GPU node disrupted at a time. Drift is blocked during the 09:00–23:00 SGT peak. Pods carry `karpenter.sh/do-not-disrupt`. `terminationGracePeriod: 1h` bounds how long they can hold a node that has to be replaced. |
| Sensible limits | `nvidia.com/gpu: 16` on spot and `8` on on-demand, plus CPU and memory caps. These stop a runaway HPA or a bug from buying unlimited GPUs. Instance families `g5`/`g6`/`g6e` with 1–4 GPUs; no 8-GPU training boxes. |
| Node hygiene | Bottlerocket (the NVIDIA variant is selected automatically), IMDSv2 only with hop limit 1, encrypted gp3 volumes, and a 200 Gi data volume for large model images. |

## Spot vs on-demand for AI inference

Spot GPUs are typically far cheaper than on-demand: often more than half off, though the discount varies by family, region and time. Inference is mostly stateless request/response. That makes it a good spot candidate, unlike multi-hour training jobs, which would lose their progress. The catch is that GPU spot capacity is scarcer and more volatile than CPU, and an interruption hurts more:
- **2-minute notice.** In-flight requests must finish or be retried.
- **Expensive restarts.** A replacement node must pull a large image and load the model weights into GPU memory, which can take minutes. During that time capacity is reduced.

So I would keep a **baseline of on-demand capacity sized for minimum traffic and latency-SLO requests**, and serve bursts and best-effort traffic on spot spread across several GPU families and AZs. Graceful shutdown (stop accepting work, drain in-flight requests within the notice) and client retries make interruptions invisible to users. The weighted NodePools here encode the fallback. The baseline itself is set per workload with a spread constraint, or a dedicated on-demand deployment, in the same way Part 2 guarantees an on-demand replica.
