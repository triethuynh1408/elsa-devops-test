# Part 4: GitLab CI → GitHub Actions migration notes

Legacy: `ci/legacy.gitlab-ci.yml` → New: `.github/workflows/ci.yml`

I migrated the **intent** (test → quality gate → build → deploy), not the file. Every job of the legacy pipeline had a practice we want to leave behind.

```
test ─┐
      ├─> build ─> Trivy gate ─> push (amd64+arm64) ─> cosign sign ─> deploy (commit new tag → ArgoCD)
sast ─┘
Pull requests: test + SAST + build + Trivy. Nothing is pushed or deployed.
```

## What changed and why

| Legacy (GitLab) | Problem | New (GitHub Actions) |
|---|---|---|
| `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` in `variables:` | Long-lived credentials committed in plain text. Even "example" values train people to put keys in YAML. Every fork and every log gets them. | **Deleted.** The pipeline pushes to GHCR, so no AWS access is needed. If AWS were needed: **GitHub OIDC → IAM role** (`aws-actions/configure-aws-credentials` with `role-to-assume`), with short-lived credentials scoped to this repo and branch. There is nothing to store and nothing to rotate. |
| `sonar_check` with `allow_failure: true` | A scan that can never fail is decoration. Findings never block anything. | **Semgrep with `--error`**: any finding fails the job, and `build` needs it (`needs: [test, sast]`). Verified both ways: exit 1 on a known-bad file, exit 0 on our code. |
| `sonar-scanner-cli:4.6`, `-Dsonar.login=` | Old scanner. A token passed on the command line can leak in logs and the process list. | Semgrep in a pinned container image, using registry rulesets (`p/python`, `p/dockerfile`, `p/secrets`, `p/github-actions`). There is no token at all, so nothing can leak. |
| `npm test \|\| echo "tests flaky, continuing"` | Swallows every failure. "Flaky" tests are either fixed or quarantined, never ignored. | `python -m pytest -q`. A failure fails the pipeline. |
| `node:16`, `docker:20.10`, `bitnami/kubectl:1.24` | End-of-life images, unpatched. | Current, pinned versions. **Actions are pinned by commit SHA** (with the version in a comment), because tags can be moved by an attacker (the tj-actions/changed-files incident). Tool images are pinned by version. |
| `only: [master]` on every job | No validation on merge requests: problems are found after they land on the main branch. | Tests, SAST, build and Trivy run on **every PR**. Publishing and deploying happen only on `main`. |
| `docker login -p "$CI_REGISTRY_PASSWORD"` | Password on the command line: visible in the process list and shell history. | `docker/login-action` with the job's **auto-generated `GITHUB_TOKEN`**. It is short-lived, scoped to `packages: write`, and nothing is stored. |
| `docker:dind` service | Privileged Docker-in-Docker, slow, and no layer cache. | Buildx on the runner, with the GitHub Actions layer cache (`type=gha`) and QEMU for arm64. |
| Tag `:latest` only | Mutable: nobody can tell what is running, and rollback is impossible. | Tag = **short git SHA** (immutable, traceable to a commit). `latest` is kept only as a convenience. Multi-arch (amd64 + arm64). |
| No image scanning | Known CVEs ship to production. | **Trivy gate** on HIGH/CRITICAL with a fix available, run **before** the push, so a vulnerable image is never published. |
| No provenance | Nobody can prove that an image came from this pipeline. | **cosign keyless signing** by digest, with the workflow's OIDC identity. There is no signing key to manage. |
| `deploy_prod`: `kubectl set image` with `KUBECONFIG_CONTENT` secret, `when: manual` | Cluster-admin credentials stored in CI. The imperative change drifts from Git, and GitOps would revert it. The manual click is not auditable. | **GitOps.** CI commits the new tag to `charts/quote-api/values.yaml`, and ArgoCD (Part 2) syncs it. CI never holds cluster credentials. History and rollback are `git log` / `git revert`. The manual gate becomes a GitHub **environment** (`production`) with required reviewers. |
| Global `variables:` visible to all jobs | Every job can read every secret. | `permissions: {}` at the top. Each job declares only what it needs: `contents: read`, `packages: write`, `id-token: write`, `contents: write`. |

## Gate decisions

- **Semgrep over SonarQube/SonarCloud:**
  - No server to run, and no token or account.
  - Rulesets are versioned with the run, and it fits a single small service.
  - Trade-off: no quality dashboard or coverage tracking. SonarCloud would add those, and is free for public repos.
- **It caught a real issue on the first run:**
  - Finding: `python.flask.security.audit.app-run-param-config.avoid_app_run_with_bad_host`. The local-dev `app.run(host="0.0.0.0")` exposes the dev server on every interface.
  - Fix: I changed the code (loopback by default, `HOST` env to override). I did not add a `# nosemgrep` suppression.
- **Trivy with `--ignore-unfixed`:**
  - The `python:3.12-slim` (Debian 13) base has 44 HIGH CVEs in OS packages such as `bsdutils` and `libblkid1`. None of them has a fix yet.
  - Blocking on unfixable CVEs makes the gate permanently red, and a permanently red gate gets disabled. So the gate blocks what we *can* fix, and the unfixed ones are visible in the job log.
  - Next steps: a distroless/Chainguard base (most of those packages aren't present), plus a scheduled rebuild so fixes land without a code change.
- **Scan before push:** the amd64 image is built with `load: true` and scanned. Only if it passes is the multi-arch image built (from cache) and pushed.

## Migrating GitLab CI variables and secrets in a real project

1. **Inventory.** Export the project and group CI/CD variables through the GitLab API (`GET /projects/:id/variables`, `/groups/:id/variables`). Sort each one into: config (not secret), secret, or credential that can be replaced by OIDC.
2. **Delete before you migrate.** Anything an OIDC federation can replace is not migrated at all:
   - AWS keys → GitHub OIDC + IAM role.
   - Registry passwords → `GITHUB_TOKEN`.
   - Kubeconfigs → GitOps, so CI needs no cluster access.
3. **Map scopes.**
   - GitLab *protected* variables (protected branches only) → GitHub **environment secrets** on an environment limited to `main`, with required reviewers for production.
   - Group variables → **organization secrets**, restricted to selected repositories.
   - Masked config values that aren't secret → plain **variables** (`vars.*`), not secrets.
4. **Move values without exposing them.** Use `gh secret set NAME --env production < value-file` (or the API with sealed-box encryption). Never put values in workflow files, chat, or tickets.
5. **Rotate after cutover.** Every secret that lived in GitLab is treated as exposed to its history and runners. Issue new values in GitHub, then revoke the old ones.
6. **Prefer a secret manager for runtime secrets.** Application secrets belong in AWS Secrets Manager + External Secrets Operator (see `OPS-ANSWERS.md`), not in CI at all. CI only needs build- and deploy-time identity.
7. **Decommission.** Disable the GitLab pipeline once GitHub has been green for a release cycle, then delete the variables there.

## One-time repository setup (done in the GitHub UI)

- **Package `quote-api` → Package settings → Manage Actions access:** add this repo with the **Write** role. Without it, `GITHUB_TOKEN` gets `403` when pushing to a package that was first created from a laptop.
- **Optional:** Settings → Environments → `production` → required reviewers, to turn deploy into a manual approval.

## Verify a signed image

```bash
cosign verify ghcr.io/triethuynh1408/quote-api:<sha> \
  --certificate-identity-regexp '^https://github.com/triethuynh1408/elsa-devops-test/\.github/workflows/ci\.yml@refs/heads/main$' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```
