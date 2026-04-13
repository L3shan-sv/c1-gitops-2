# Tool selection — rationale and design decisions

This document explains why each tool in this pipeline was chosen, what alternatives were considered, and the tradeoffs that shaped the design. It is intended as a reference for engineers joining the project and as an audit trail for architectural decisions.

---

## Continuous delivery — ArgoCD

**What it does:** Watches this Git repository and continuously reconciles the Kubernetes cluster to match. It is the enforcement mechanism for the GitOps principle — Git is the only source of truth for cluster state.

**Why ArgoCD over alternatives:**

Flux is the closest competitor and is technically excellent. The decisive factor here was the ArgoCD UI: it provides a live diff between Git state and cluster state, a visual application tree showing every deployed resource and its health, and a one-click sync gate for production deployments. For a team that needs a named human to approve production deploys and wants a clear audit trail, the UI removes friction that would otherwise require custom tooling.

Spinnaker was ruled out for operational complexity — it is a substantial platform to run and maintain, suited to organisations with dedicated platform teams. Jenkins X was considered and rejected because it conflates CI and CD in ways that make the boundary hard to enforce; this pipeline keeps CI in `gitops-demo-app` and CD entirely in this repository.

**Key configuration decisions:**

The ArgoCD Project (`argocd/projects/gitops-project.yaml`) enforces three hard boundaries: sources (only this repository), destinations (only dev/staging/prod namespaces), and a resource whitelist (only the resource types the application actually needs). Orphaned resource monitoring is on, so any `kubectl apply` that bypasses Git will surface as an alert rather than silently persisting.

The production application (`argocd/apps/myapp-prod.yaml`) has `automated: {}` removed entirely. ArgoCD will never auto-sync prod regardless of what commits appear in this repository. A human opens the ArgoCD UI, reviews the diff, and clicks Sync. This creates a timestamped audit record tied to an individual identity — not a shared `admin` account.

---

## Image promotion — ArgoCD Image Updater

**What it does:** Watches ECR for new image tags matching `^[0-9a-f]{7}$` (7-character git SHA). When a new tag appears, it commits the updated image reference to `k8s/overlays/dev/kustomization.yaml` and pushes to `main`. ArgoCD then detects the commit and syncs dev automatically.

**Why this pattern:**

The alternative is having the CI pipeline (Jenkins) write directly to this repository after a successful build. That approach is common but has a significant downside: Jenkins needs write credentials for the deploy repository. The Image Updater pattern removes that coupling entirely. Jenkins has no credentials for this repository and cannot write to it. The only entity with Git write access is Image Updater, whose IAM role is scoped to ECR read-only for the registry side.

This means the deploy repository can enforce branch protection rules (no direct pushes, PRs required for human changes) without creating exceptions for the CI system. Image Updater's commits are the only writes that bypass PR review, and they are structurally limited to a single line change: the image tag in a kustomization overlay.

**Git credentials:** Image Updater's Git credentials are provisioned separately from the rest of the bootstrap by `bootstrap/scripts/02-image-updater-secret.sh`. The script supports both GitHub App authentication (recommended for organisations — no expiry, fine-grained repository scope) and fine-grained personal access tokens. The credentials are stored in the `argocd-image-updater-secret` Kubernetes Secret in the `argocd` namespace.

---

## Progressive delivery — Argo Rollouts

**What it does:** Replaces the standard Kubernetes `Deployment` in production with a `Rollout` resource that implements a canary strategy. Traffic is shifted gradually: 10% → 50% → 100%, with automated analysis gates between steps.

**Why canary over blue/green:**

Blue/green requires double the production capacity for the duration of a deployment — two complete environments running simultaneously. At m5.large with autoscaling, that cost is acceptable for a brief window but wasteful if deployments are frequent. Canary shifts traffic progressively within a single environment and requires no additional node capacity beyond what the HPA might provision.

**The analysis template (`k8s/base/analysis-template.yaml`):**

Three metrics run in parallel during each analysis window:

1. **Smoke test job** — A Kubernetes Job running `curlimages/curl` fires 60 HTTP requests at `/health` before Prometheus queries execute. This solves the vacuous pass problem: if Prometheus has no data (zero traffic to the canary at 10% weight in a low-traffic environment), a PromQL query can return NaN or empty, which some analysis implementations treat as passing. By generating synthetic traffic first, we guarantee Prometheus has real data points.

2. **Success rate** — The corrected query: numerator filters `endpoint!="not_found"`, denominator is unfiltered total. The original formulation applied the same label filter to both sides, meaning the rate was always exactly 1.0 regardless of actual error conditions. `inconclusiveLimit: 1` is set so empty Prometheus data aborts the rollout rather than passing.

3. **p99 latency** — `histogram_quantile(0.99, ...)` must be ≤ 500ms. Same `inconclusiveLimit: 1` guard.

If analysis fails at either gate, Argo Rollouts immediately routes 100% of traffic back to the stable version and marks the rollout `Aborted`. The `RolloutAborted` alert fires within one minute. No human action is required to execute the rollback.

---

## Manifest management — Kustomize

**What it does:** Manages the Kubernetes manifests for the application. A `base/` directory holds everything shared across environments. Overlays hold only the differences — replica counts, node selectors, hostnames, and environment-specific resources like the production NetworkPolicy, PodDisruptionBudgets, and Rollout.

**Why Kustomize over Helm for application manifests:**

Helm uses a template model: every shared value becomes a `{{ .Values.x }}` expression, and the template is rendered at deploy time. Kustomize uses a patch model: the base directory holds valid, unmodified Kubernetes YAML, and overlays apply strategic merge patches or JSON patches on top. There is no template syntax and no risk of a typo in a `{{ }}` block silently rendering an empty string or an unexpected value.

For manifests you own and control, Kustomize is the right tool. For third-party software (ArgoCD, Vault, Prometheus, the ALB controller), Helm is the right tool — it is the distribution standard for off-the-shelf Kubernetes software, and Helm charts encode the operational knowledge of those projects' maintainers.

**Overlay structure:**

The `overlays/` directory is a sibling of `base/`, not a child of it. This is a hard Kustomize requirement: a `kustomization.yaml` in an overlay must be able to reference `../../base` as its resource path, which only works if they are siblings. Nesting overlays inside base breaks this path and causes `kustomize build` to fail silently in some versions and loudly in others.

---

## Infrastructure — Terraform + Atlantis

**What it does:** Terraform provisions all AWS infrastructure: VPC, EKS cluster, ECR repository, IAM roles (IRSA), and Vault via a Helm release. Atlantis provides a PR-based workflow for infrastructure changes so that every `terraform apply` has a reviewed plan attached to it.

**Module design:**

Each module is self-contained with its own `variables.tf` and `outputs.tf`. No module contains environment-specific logic — differences between dev, staging, and prod are expressed entirely through variable values passed from `terraform/environments/<env>/main.tf`. This means the module code is identical across all three environments, and only the inputs differ.

**Vault module — KMS auto-unseal:**

The updated vault module (`terraform/modules/vault/`) creates a KMS key per environment (skipped for dev) and configures Vault to use it for auto-unseal via the `seal "awskms" {}` stanza in the Helm values template. Without this, every Vault pod restart — whether from a node drain, cluster upgrade, or crash — requires a human to run `vault operator unseal` before the application can retrieve secrets. In staging and prod, where node replacements are routine, manual unseal is operationally unacceptable.

Dev uses Shamir unseal. The bootstrap script initialises Vault and unseals it using the first three of five generated key shares. The init output (containing all five key shares and the root token) is written to `/tmp/vault-init-dev.json` and must be moved to a password manager immediately.

**Atlantis:**

For staging and prod, all infrastructure changes go through a pull request. Atlantis runs `terraform plan` on the PR branch and posts the output as a PR comment. A reviewer reads both the code diff and the plan output before approving. The reviewer then comments `atlantis apply` and Atlantis applies the change. The PR is merged after apply. No engineer applies Terraform locally to staging or prod under any circumstances.

Remote state is stored in S3 with DynamoDB locking. Concurrent applies are structurally impossible.

---

## Secrets — HashiCorp Vault + IRSA

**What it does:** Application pods receive secrets as files injected by the Vault Agent sidecar, not as environment variables. The Vault Agent is injected automatically based on annotations on the Pod spec. Vault itself authenticates to AWS using the Kubernetes auth backend, which trusts the pod's ServiceAccount JWT.

**Why files over environment variables:**

Environment variables are visible in `kubectl describe pod`, in crash dumps, in application logs if the framework logs its configuration, and to any process that can read `/proc/<pid>/environ`. Files mounted to a specific path are accessible only to processes that explicitly open them. The blast radius of a secret leak via files is meaningfully smaller.

**Why IRSA over static credentials:**

IRSA (IAM Roles for Service Accounts) uses the EKS OIDC provider to issue short-lived STS tokens to pods based on their ServiceAccount identity. There are no `AWS_ACCESS_KEY_ID` or `AWS_SECRET_ACCESS_KEY` values anywhere in this system — not in manifests, not in environment variables, not in Vault. Tokens rotate automatically. An IAM role is scoped to a specific ServiceAccount in a specific namespace, so a compromise of one pod's credentials cannot be used from a different namespace or a different service.

---

## Image signing — Cosign + OPA Gatekeeper

**What it does:** Every image built by the CI pipeline is signed with Cosign using a private key stored in Jenkins credentials. At admission time, OPA Gatekeeper verifies the signature against the public key committed to `k8s/policies/cosign-constraint.yaml` before allowing the pod to be scheduled.

**The policy files (`k8s/policies/`):**

These files were missing from the original repository despite the README claiming Cosign verification was active. Without the `ConstraintTemplate` and `Constraint` resources applied to the cluster, unsigned images run freely and no alert fires. The `cosign-constraint-template.yaml` defines the Rego policy logic. The `cosign-constraint.yaml` activates enforcement for the `staging` and `prod` namespaces only; dev is excluded to allow unsigned images during feature development.

The constraint starts with `enforcementAction: deny`. When rolling this out to an existing cluster for the first time, change this to `warn` initially, monitor for violations in Gatekeeper's audit output, sign all existing images, then switch to `deny`. This avoids a hard outage if any currently-deployed images lack signatures.

**OPA Gatekeeper over Kyverno:**

Kyverno uses a YAML-native policy language and is easier to read for engineers who are not familiar with Rego. Gatekeeper uses Rego (Open Policy Agent's policy language), which is more expressive and composable for complex policies. The choice here is Gatekeeper because the Cosign verification logic requires evaluating pod annotations injected by the admission webhook, which is more naturally expressed in Rego than in Kyverno's YAML DSL.

---

## Networking — AWS VPC + ALB + NetworkPolicy

**VPC design:**

Each environment gets its own VPC with non-overlapping CIDR blocks (dev: 10.0.0.0/16, staging: 10.1.0.0/16, prod: 10.2.0.0/16). Six subnets: three public (one per AZ, for the ALB), three private (one per AZ, for EKS nodes). NAT Gateways: one in dev/staging (cost optimisation), one per AZ in prod (HA egress — a single NAT Gateway failure in prod would take the application offline).

**ALB + AWS Load Balancer Controller:**

The Ingress resource in `k8s/base/ingress.yaml` is managed by the AWS Load Balancer Controller, which provisions an Application Load Balancer automatically when the Ingress is applied. TLS termination happens at the ALB using an ACM certificate referenced by ARN annotation. HTTP traffic is redirected to HTTPS at the ALB level before it reaches any pod. The ALB Controller requires an IRSA role and must be installed before any Ingress resources are applied — this is handled by `bootstrap/scripts/01-bootstrap.sh`.

**NetworkPolicy (prod only):**

The production overlay includes a NetworkPolicy that locks down pod-level traffic. Ingress is allowed only from the ALB controller (port 8080) and from Prometheus (port 8080 for scraping). All other ingress is denied. Egress is allowed only to DNS (port 53) and HTTPS (port 443) for AWS API calls. A compromised production pod cannot reach other namespaces, cannot reach the Kubernetes API server directly, and cannot make arbitrary outbound calls.

---

## Observability — Prometheus + Grafana + AlertManager

**Prometheus** scrapes all annotated pods every 15 seconds and stores 15 days of metrics. Alert rules evaluate continuously. The two queries in the canary AnalysisTemplate (`k8s/base/analysis-template.yaml`) query this same Prometheus instance, which means the same metrics that trigger PagerDuty alerts also gate production deployments.

**Grafana** renders a DORA metrics dashboard: deployment frequency, lead time for changes, change failure rate, and mean time to recovery. These four metrics were chosen specifically because they measure the pipeline's output quality, not just its activity. High deployment frequency with a high change failure rate is worse than low frequency with zero failures.

**AlertManager** routes critical alerts to PagerDuty and warnings to Slack. Grouping and inhibition rules prevent alert storms: if the cluster is under load, AlertManager suppresses individual pod-level alerts and surfaces only the aggregate.

**Fluent Bit** collects structured JSON logs from all pods and ships to CloudWatch Logs. Application pods are expected to emit structured JSON on stdout; the `deployment.yaml` does not configure a log rotation sidecar because CloudWatch's log group retention handles archival.

---

## Bootstrap layer

The `bootstrap/` directory was added to address a gap in the original repository: the README described a working system but provided no mechanism to bring that system into existence on a fresh AWS account. A new engineer following the original documentation would reach a point where ArgoCD, Argo Rollouts, OPA Gatekeeper, and the ALB Controller were assumed to exist with no instructions for creating them.

`01-bootstrap.sh` is idempotent. Helm uses `upgrade --install`, `kubectl apply` is declarative, and the secret script deletes and recreates the target secret. Re-running the script after a partial failure is safe.

The install order within the script is load-bearing:

1. AWS Load Balancer Controller — must be running before any `Ingress` resource is applied, otherwise the ALB annotation is ignored and pods are unreachable.
2. OPA Gatekeeper — must be running and its webhook must be `Ready` before the Cosign policy manifests are applied. Applying a `ConstraintTemplate` before Gatekeeper is ready causes admission failures on unrelated namespaces.
3. Argo Rollouts — must be running before ArgoCD syncs the prod `Rollout` resource, otherwise ArgoCD marks the resource as `Unknown` health.
4. ArgoCD — installed last so it can immediately manage everything already in place.
5. ArgoCD project, then apps, then Image Updater — project must exist before apps reference it; Image Updater must have its Git credentials secret before it can commit.
