# AI Usage Disclosure

## Tools and where they were used

**Claude Code** (Anthropic, running in VS Code) was my only AI tool. It worked as a pair programmer with shell access to my machine and the local cluster: it read the assignment, wrote code and docs, ran commands, and reported results. I used it in every part:

| Part | What the AI did | What I did |
|---|---|---|
| 1. Service & image | Proposed Python (easiest to explain) and wrote `app.py`, the Dockerfile and the build script; tested them locally | Created the repo, built and pushed the image, made the GHCR package public |
| 2. Cluster & GitOps | Designed the compose → k3d harness, Helm chart, placement rules and drill; looked up current versions | Ran the golden path from scratch (this is how the drill bug below was found); asked for the reasoning behind placement, ingress and the run-all flow |
| 3. Troubleshooting | Diagnosed live, one layer at a time; wrote `fixed-app.yaml` and `TROUBLESHOOTING.md` | Reviewed the write-up and the fixes |
| 4. CI/CD | Wrote the workflow and `MIGRATION-NOTES.md`; ran Semgrep, Trivy and actionlint locally first | Chose Part 4 among Parts 4–6; granted the package's Actions access; pushed; watched the run, the bot's tag commit and the ArgoCD rollout |
| 7. Ops answers | Drafted the answers within the 1.5-page limit | Reviewed them |

From the start I asked for every step to come with an explanation I could defend in an interview. The AI's working rule, which I kept: no version from memory (look it up live), and nothing is "done" without a command output proving it.

## Prompts that actually moved the work forward

1. **Setting the working contract at the start:**
   > "Read the md file carefully and unzip the zip if it looks safe. Prepare everything for task 1 first. Guide me so I can follow each step and still answer when asked in the interview."

   Two things came out of this. First, the AI inspected the zip's listing, file modes and contents *before* extracting (no binaries, no path traversal). Second, every part from then on came with a written "why" guide, not just code.

2. **Pasting a failing fresh run instead of re-running until green.** I ran `docker compose up -d && ./scripts/run-all.sh` on a clean machine. The drill failed with `49 requests failed`, and I pasted the full output and asked:
   > "There are 2 Traefik replicas — why does one pod going away break the app?"

   This led to the root-cause investigation below, and to a real fix instead of a retry.

3. **Pushing past "it works" to "how do you know":**
   > "If I test locally, how do I know it's the right key for that image from the right pipeline? And how would Kyverno know the right signing key?"

   This turned keyless signing from a checkbox into something I can explain: a per-build ephemeral key, a Fulcio certificate bound to the workflow identity, Rekor proof, and Kyverno verifying the *identity* rather than a key. It also produced a negative test: the laptop-built image `ccaabb7` fails `cosign verify` with `no signatures found`.

## Where the AI was wrong or suboptimal, and how it was caught

### 1. A drill that passed in testing but failed on a fresh cluster (the most important one)
- **What happened.** The AI tested the reclaim drill (39/39 OK) and handed it over. On my clean golden-path run it failed: **49/60 requests reset**.
- **How it was found.** The first two hypotheses were wrong, and the experiments disproved them before anything was "fixed":
  - *"Traefik wasn't finished installing."* The helm jobs had completed 2 minutes earlier.
  - *"A terminating Traefik pod causes it."* Deleting a Traefik pod gave 0/70 failures.
  - The breakthrough was comparing the passing and failing runs: it failed **only when the drained spot node hosted a Traefik pod**. Draining exactly that node with per-request curl errors and per-second endpoint logs reproduced it: **50/80 failures, `Connection reset by peer`**.
- **Root cause.** The terminating Traefik refused new connections while kube-proxy still routed to it. The k3d load balancer (`max_fails=1 fail_timeout=10s`) then marked every node down, so the whole ingress went dark for ~10s while a healthy Traefik replica was still serving.
- **Fix.** `requestAcceptGraceTimeout=10s` for Traefik (the same `preStop` idea the app already had), and bootstrap now waits for Traefik to run with it.
- **Result.** 0/90 on two consecutive targeted drains, then 55/55 on a full from-scratch golden path that drained a Traefik node.
- **Lesson.** The AI applied graceful shutdown to the app but not to the ingress pod on the same traffic path. Only a fresh end-to-end run exposed it. Commit `e4c0556`.

### 2. AI-written code that the quality gate rejected
- **What happened.** In Part 1 the AI wrote `app.run(host="0.0.0.0")` for the local dev server.
- **How it was caught.** When the Semgrep gate was built in Part 4, its first run flagged it (`avoid_app_run_with_bad_host`).
- **Fix.** I fixed the code (loopback by default, `HOST` to override) rather than adding `# nosemgrep`.
- **Verification.** The gate was then proven both ways: exit 1 on a known-bad file, exit 0 on our code. A gate that has never been seen to fail is not proven to work.

### 3. A bug the AI caught in its own code before testing
- **What happened.** The first SIGTERM handler replaced gunicorn's own handler.
- **Why it matters.** Gunicorn installs its handler before importing the app, so the worker would never exit gracefully and would wait to be SIGKILLed.
- **Fix.** The handler now chains to the previous one.
- **Verification.** `docker stop` takes ~1s and the logs show `Worker exiting`.

### 4. Advice that hid my real kubeconfig
- **What happened.** The AI told me to `export KUBECONFIG=$PWD/kubeconfig` to reach the local cluster. Afterwards `kubectl` showed only the k3d cluster, and I asked why my old kubeconfig had been "deleted".
- **What was actually wrong.** The file was intact. The export shadowed `~/.kube/config`, and that config includes **production** EKS contexts.
- **Fix.**
  - The guidance changed to per-command use (`KUBECONFIG=./kubeconfig kubectl ...`) or the toolbox, which can only see the k3d cluster.
  - The generated kubeconfig was also world-readable (`644`); bootstrap now `chmod 600`s it.

### 5. Smaller errors caught by checking output
- **Documentation honesty.** The `TROUBLESHOOTING.md` draft quoted an `endpointslices` output for a command that had never been run. I replaced it with the real output of the command that was run. Docs only contain observed output.
- **`.gitignore` corruption.** An append merged two lines and silently **un-ignored** the assignment file. `git check-ignore -v` caught it.
- **Breaking a constraint.** The first `OPS-ANSWERS.md` was 1,296 words against a 1.5-page limit; I cut it to ~900.
- **Tool mistakes.** A wrong `actionlint` flag (`-color=never`), and bash's `PIPESTATUS` used in zsh, which hid an exit code. Both were noticed because the output didn't match expectations.

## How AI output was verified (what "done" meant)

- **Versions looked up live, never from model memory:**
  - k3s stable channel, GitHub releases (`git ls-remote` for action commit SHAs), Docker Hub tags, PyPI;
  - toolbox binaries verified against published checksums;
  - actions pinned by commit SHA.
- **Negative tests, not just happy paths:**
  - NetworkPolicy: internet, other namespaces and unlabelled pods stay **blocked**;
  - cosign rejects the unsigned image;
  - Semgrep fails on bad code;
  - draining **both** spot nodes falls back to on-demand instead of Pending.
- **Live, layer-by-layer diagnosis** in Part 3 (patch, observe the next failure), rather than fixing everything from reading YAML.
- **The reviewer's path, from scratch:** `99-teardown` → `docker compose up -d` → `./scripts/run-all.sh`. It was run again after every significant change.

## What I own

The AI wrote most of the code and prose. I directed the work, ran it end to end, pushed back when results didn't add up, and studied each part until I could explain it. Where I accepted a trade-off the AI proposed, the reasoning is in the README's "Design decisions" and "What I cut". The cases above are where its first answer wasn't good enough, and they didn't ship as-is.
