# Part 7: Ops Questions

## 1. EKS 1.33 → 1.35, zero downtime

EKS moves one minor at a time, so this is **two passes (1.33 → 1.34 → 1.35)**, each in this order:

0. **Prepare.**
   - Run EKS Upgrade Insights and `pluto`/`kubent` against manifests *and* Helm releases.
   - Read the release notes.
   - Upgrade controllers (Karpenter, LB controller, ESO, Argo) to versions that support the target.
   - Rehearse on staging.
   - Workloads must already be drain-safe: ≥2 replicas, PDBs, `preStop`, readiness probes.
1. **Control plane.** AWS-managed and in place; the API stays available.
2. **Add-ons**, at the versions recommended for the new minor:
   - **vpc-cni** first;
   - then **kube-proxy** and **coredns**;
   - then **EBS/EFS CSI** (controller, then node DaemonSet).

   Kubelet/kube-proxy may lag the API server, never lead it.
3. **Nodes.**
   - Managed node groups: rolling replace.
   - Karpenter: bump the AMI in the `EC2NodeClass` and let **drift** replace nodes within its disruption budgets.
   - Go in small batches, watching SLOs between them.

**Top risks**
1. **Removed APIs or stale CRD controllers.** The control plane **can't be rolled back**. *Mitigation:* insights/pluto as a CI gate, staging first, controllers before the control plane.
2. **Drains causing downtime.** Single replicas, missing `preStop`, or PDBs so strict they block drains. *Mitigation:* audit PDBs and rotate with surge capacity.
3. **Add-on or storage regressions.** CNI/DNS breakage, or EBS volumes stuck in one AZ. *Mitigation:* one add-on at a time with canary checks; zonal pools for stateful workloads.

## 2. Spot reclaims paging at 3 AM

**Principle:** a reclaim is routine and announced 2 minutes ahead. **Page on user impact and capacity, not on an expected spot death.**

- **Handle it before it is "unreachable."** Karpenter's interruption queue (or Node Termination Handler) consumes the EventBridge interruption and rebalance events. It cordons, drains and deletes the node, and a cleanly deleted node never fires `KubeNodeUnreachable`.
- **Suppress what is explained.** Drop node alerts for `karpenter.sh/capacity-type=spot` nodes that had an interruption event in the last 10 min (the handler exposes it as a metric; join it in the rule). Give the remaining spot `NotReady` alerts `for: 10m` and route them to Slack, not the pager.
- **Still page on:**
  - on-demand/system nodes `NotReady` > 3 min;
  - a `NotReady` node whose **EC2 instance is still running** with no interruption (a real fault);
  - **>20% of a pool or an AZ** down at once;
  - **symptoms**: SLO burn rate (multi-window), ready replicas below PDB `minAvailable`, pods Pending > 10 min (no spot capacity anywhere).
- **Alertmanager:** `group_by: [cluster, nodepool, zone]`. Inhibit node alerts while a pool-level capacity or SLO alert is firing.
- **Prove it.** Run reclaim game days on staging (the Part 2 drill), and track pages per week that needed action.

## 3. Mobile LCP 5 s behind Cloudflare

1. **Locate the time.** CrUX/PageSpeed field data plus a throttled mobile WebPageTest run. If TTFB is high, suspect caching. If TTFB is fine, it's the front-end (step 5).
2. **Edge headers.** Run this twice with a mobile UA:
   ```bash
   curl -sI -A "Mozilla/5.0 (iPhone...)" https://site/ | grep -iE 'cf-cache-status|age|cache-control|set-cookie|vary'
   ```
   - `DYNAMIC` = not eligible. This is Cloudflare's **default for HTML**: it needs a Cache Rule "Eligible for cache".
   - `BYPASS` = a rule or cookie is skipping the cache.
   - `MISS` every time = the cache key is fragmented or the TTL is 0.
   - `HIT` with a rising `age` = caching works; go to step 5.
3. **Rules.**
   - Is there a Cache Rule for the HTML paths?
   - Check rule order (later rules win) and Page Rules or Workers overriding it.
   - Check Edge TTL vs. the origin's TTL.
   - The cache key may split on `utm_*`/`fbclid` or device type. Ignore marketing params and enable Tiered Cache.
4. **Origin.** `curl --resolve site:443:<origin-ip>` and compare.
   - Typical culprits: `Cache-Control: private/no-store`, a `Set-Cookie` on anonymous pages, `Vary: Cookie/User-Agent`, slow TTFB.
   - Fix: public `s-maxage` for anonymous HTML, and bypass only for login cookies.
5. **Cached but still slow? It's the page.** Oversized or unprioritised hero image (`fetchpriority=high`, preload, Polish/Images resizing), render-blocking CSS/JS, late fonts.
6. **Re-measure.** Cache hit ratio in Cloudflare Analytics; CrUX takes ~28 days to fully reflect changes.

## 4. Application secrets on EKS

| | **External Secrets Operator + Secrets Manager** | **Secrets Store CSI Driver (ASCP)** |
|---|---|---|
| Model | Controller syncs into native K8s `Secret`s; apps unchanged | Files mounted into each pod at start |
| GitOps | `ExternalSecret` (a reference, no value) in Git, deployed by Argo | `SecretProviderClass` in Git |
| Rotation | `refreshInterval` plus a pod reload (Reloader) | Rotation reconciler; app must re-read files |
| Cost | Values sit in etcd → KMS envelope encryption + tight RBAC | Pod start depends on the AWS API; env vars need sync-to-Secret anyway |

**Pick: ESO + AWS Secrets Manager.**
- **One source of truth for every cluster**, with CloudTrail audit and native rotation.
- **Least-privilege identity per cluster.** Each cluster gets a `ClusterSecretStore` on an IAM role via EKS Pod Identity, scoped by path (`/prod/<app>/*`).
- **Fits what we have.** GitOps and Helm work with no app changes, and pods still restart during an AWS API blip.
- **Guardrails:** KMS encryption, RBAC per service account, alerts on sync failures, and no secrets in Git or CI (Part 4 holds no long-lived credentials).

**Rejected:** Sealed Secrets/SOPS. Per-cluster keys and no central rotation or audit are painful across several production clusters.
