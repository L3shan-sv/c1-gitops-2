# gitops-demo-deploy

> CD and infrastructure repository for the GitOps pipeline. This is the source of truth for everything running in the cluster.

ArgoCD watches this repository continuously and reconciles the cluster to match. No one runs `kubectl apply` manually. No one SSHes into anything. Every change to what runs in production is a commit here — auditable, reviewable, and instantly revertable with `git revert`. The companion CI repository `gitops-demo-app` builds and signs Docker images. This repository deploys them.

---

## Repository structure

```
gitops-demo-deploy/
│
├── argocd/
│   ├── apps/
│   │   ├── appsets/image-updater.yaml        # Image Updater — writes SHA tag back to repo
│   │   ├── myapp-dev.yaml                    # Dev — auto-sync
│   │   ├── myapp-staging.yaml                # Staging — auto-sync
│   │   └── myapp-prod.yaml                   # Prod — manual sync gate
│   └── projects/
│       └── gitops-project.yaml               # Project scope: sources, destinations, resource types
│
├── bootstrap/                                # NEW — run once per environment
│   ├── README.md                             # Step-by-step bootstrap runbook
│   ├── helm-values/
│   │   ├── argocd-values.yaml
│   │   ├── argo-rollouts-values.yaml
│   │   ├── aws-load-balancer-controller-values.yaml
│   │   └── gatekeeper-values.yaml
│   └── scripts/
│       ├── 01-bootstrap.sh                   # Main runbook script
│       └── 02-image-updater-secret.sh        # Git credentials for Image Updater
│
├── k8s/
│   ├── base/
│   │   ├── kustomization.yaml
│   │   ├── analysis-template.yaml            # NEW — canary smoke test + fixed PromQL
│   │   ├── deployment.yaml                   # Non-root, read-only FS, Vault sidecar
│   │   ├── hpa.yaml                          # CPU 70% / memory 80%
│   │   ├── ingress.yaml                      # ALB, TLS via ACM, HTTP→HTTPS redirect
│   │   ├── service.yaml
│   │   └── serviceaccount.yaml               # IRSA annotation
│   ├── overlays/
│   │   ├── dev/kustomization.yaml            # 1 replica, t3.medium
│   │   ├── staging/
│   │   │   ├── kustomization.yaml            # 2 replicas, t3.medium
│   │   │   └── poddisruptionbudget.yaml      # NEW — minAvailable: 1
│   │   ├── prod/
│   │   │   ├── kustomization.yaml            # 3+ replicas, m5.large
│   │   │   ├── rollout.yaml                  # Argo Rollouts canary strategy
│   │   │   ├── networkpolicy.yaml            # Ingress: ALB + Prometheus only
│   │   │   └── poddisruptionbudget.yaml      # minAvailable: 2
│   │   └── monitoring/
│   │       ├── prometheus/
│   │       ├── alertmanager/
│   │       └── grafana/
│   └── policies/                             # NEW — OPA Gatekeeper admission policies
│       ├── kustomization.yaml
│       ├── cosign-constraint-template.yaml   # Rego policy — verifies Cosign signatures
│       └── cosign-constraint.yaml            # Enforces on staging + prod namespaces
│
└── terraform/
    ├── environments/
    │   ├── dev/main.tf
    │   ├── staging/main.tf
    │   └── prod/main.tf
    └── modules/
        ├── vpc/
        ├── eks/
        ├── ecr/
        ├── iam/
        └── vault/                            # UPDATED — KMS auto-unseal + IRSA
            ├── main.tf
            ├── variables.tf
            ├── outputs.tf                    # NEW
            └── helm-values.yaml.tpl          # NEW — templatefile() rendered at apply
```

---

## How deployments work

```
gitops-demo-app (CI)
  └── Jenkins builds, tests, scans, signs image
        └── pushes myapp:<sha7> to ECR
              └── ArgoCD Image Updater detects new tag
                    └── commits updated image ref → overlays/dev/kustomization.yaml
                          └── ArgoCD detects diff
                                ├── dev / staging: auto-sync → apply → done
                                └── prod: waits for manual approval in ArgoCD UI
                                          └── Argo Rollouts executes canary
                                                └── 10% → analysis → 50% → analysis → 100%
                                                      ├── pass: deployment complete
                                                      └── fail: automatic rollback
```

### Environment behaviour

| | Dev | Staging | Prod |
|---|---|---|---|
| Sync trigger | Image Updater commit | Image Updater commit | Manual approval in ArgoCD UI |
| Sync mode | Auto + selfHeal + prune | Auto + selfHeal + prune | Manual |
| Deploy strategy | Rolling update | Rolling update | Canary (Argo Rollouts) |
| Replicas | 1 | 2 | 3 min — 10 max (HPA) |
| Node type | t3.medium | t3.medium | m5.large |
| Auto-rollback | On probe failure | On probe failure | On Prometheus metric failure |
| PodDisruptionBudget | — | minAvailable: 1 | minAvailable: 2 |

---

## Canary strategy (prod)

The production Rollout executes the following steps:

| Step | Action | Gate |
|---|---|---|
| 1 | Set weight 10% | — |
| 2 | Analysis 5 min | success_rate ≥ 99% AND p99 ≤ 500ms AND smoke test passes |
| 3 | Pause 2 min | bake time |
| 4 | Set weight 50% | — |
| 5 | Analysis 5 min | same thresholds |
| 6 | Pause 5 min | bake time |
| 7 | Full rollout | 100% traffic on new version |

Analysis failure at step 2 or 5 triggers an immediate automatic rollback. No human action required.

The `analysis-template.yaml` runs three metrics in parallel: a synthetic smoke-test job (60 curl requests to `/health`), Prometheus success rate, and Prometheus p99 latency. The smoke test runs first to guarantee Prometheus has real data before the metric queries execute — preventing vacuous passes in low-traffic environments.

---

## Security layers

| Layer | Mechanism | What it prevents |
|---|---|---|
| AWS credentials | IRSA — STS temp tokens, no static keys | Credential leaks, key rotation burden |
| Secrets | Vault sidecar injection — files, not env vars | Secrets visible in `kubectl describe` or logs |
| Image provenance | Cosign signature verified at admission (OPA Gatekeeper) | Unsigned or tampered images running |
| Tag immutability | ECR immutable tags | Overwriting a legitimate image tag |
| Runtime | Non-root UID 1000, read-only FS, capabilities dropped | Container escape blast radius |
| Admission | OPA Gatekeeper policies (`k8s/policies/`) | Misconfigured pods reaching the cluster |
| Network | Kubernetes NetworkPolicy (prod) | Cross-namespace traffic, unexpected egress |
| Infrastructure | Atlantis PR-based apply | Unreviewed infrastructure changes |
| Vault unseal | AWS KMS auto-unseal (staging/prod) | Pod restarts leaving Vault sealed |

---

## Getting started

See [`bootstrap/README.md`](bootstrap/README.md) for the full step-by-step.

**Quick summary:**

```bash
# 1. Create Terraform state backend (once per AWS account)
aws s3 mb s3://gitops-demo-tfstate-$(aws sts get-caller-identity --query Account --output text)

# 2. Run bootstrap for your environment
ENV=dev \
AWS_REGION=eu-west-1 \
CLUSTER_NAME=gitops-demo-dev \
GIT_METHOD=github-app \
GH_APP_ID=<id> \
GH_APP_INSTALLATION_ID=<install-id> \
GH_APP_PRIVATE_KEY_PATH=~/keys/gitops-app.pem \
./bootstrap/scripts/01-bootstrap.sh

# 3. Trigger first deploy — push to gitops-demo-app CI repo
# Image Updater will detect the new ECR tag and commit back here automatically
```

**Before the bootstrap script will work, fill in these placeholders:**

- `k8s/policies/cosign-constraint.yaml` — replace `REPLACE_WITH_BASE64_ENCODED_COSIGN_PUBLIC_KEY` and `ACCOUNT_ID.dkr.ecr.REGION.amazonaws.com/myapp`
- `bootstrap/helm-values/aws-load-balancer-controller-values.yaml` — replace `ACCOUNT_ID` and set your region
- `terraform/environments/*/main.tf` — pass `oidc_provider_arn`, `oidc_provider_url`, and `replicas` into the vault module call

---

## Rolling back production

```bash
# Option 1 — git revert (preferred — creates audit trail)
git revert HEAD
git push origin main
# ArgoCD detects the revert commit. Manual sync gate still applies in prod.

# Option 2 — ArgoCD UI
# History tab → select previous sync → Rollback
```

---

## Changes in this revision

| Area | Change |
|---|---|
| `bootstrap/` | New directory — Helm values, runbook scripts, and README for full environment bootstrap |
| `k8s/policies/` | New directory — OPA Gatekeeper ConstraintTemplate and Constraint for Cosign image verification |
| `k8s/base/analysis-template.yaml` | New — AnalysisTemplate with synthetic smoke-test job metric and fixed Prometheus success rate query |
| `k8s/base/kustomization.yaml` | Updated — adds analysis-template.yaml to resources |
| `k8s/overlays/staging/poddisruptionbudget.yaml` | New — PDB minAvailable: 1 for staging |
| `k8s/overlays/staging/kustomization.yaml` | Updated — includes PDB |
| `terraform/modules/vault/main.tf` | Replaced — adds KMS auto-unseal key, IRSA role, Helm release via templatefile() |
| `terraform/modules/vault/variables.tf` | Replaced — adds environment, aws_region, oidc_provider_arn/url, replicas |
| `terraform/modules/vault/outputs.tf` | New — exposes vault_role_arn, kms_key_id, kms_key_arn |
| `terraform/modules/vault/helm-values.yaml.tpl` | New — Vault Helm values template with conditional KMS seal block |

---

## Stack

| Concern | Tool |
|---|---|
| CD | ArgoCD · ArgoCD Image Updater · Argo Rollouts |
| Manifests | Kustomize (app) · Helm (platform tooling) |
| Infrastructure | Terraform · Atlantis |
| Secrets | HashiCorp Vault · IRSA |
| Registry | Amazon ECR (immutable tags) |
| Image signing | Cosign (verified at admission via OPA Gatekeeper) |
| Networking | AWS VPC · EKS · ALB · NetworkPolicy |
| Observability | Prometheus · Grafana · AlertManager · Fluent Bit · CloudWatch |

---

## Related repositories

| Repository | Purpose |
|---|---|
| `gitops-demo-app` | Application source code + Jenkins CI pipeline |
| `gitops-demo-deploy` | This repository — CD + infrastructure |
