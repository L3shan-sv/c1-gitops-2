gitops-demo-deploy

The CD and infrastructure repository for the GitOps pipeline. This is the source of truth for everything running in the cluster and everything the cluster runs on.


What This Repository Does
This repository has one job: define the desired state of the system. ArgoCD watches it continuously and reconciles the cluster to match. Nobody runs kubectl apply manually. Nobody SSHes into anything. Every change to what runs in production is a commit here — auditable, reviewable, and instantly revertable with a git revert.
The companion CI repository gitops-demo-app builds and signs Docker images. This repository deploys them.

Repository Structure
gitops-demo-deploy/
│
├── argocd/
│   ├── projects/
│   │   └── gitops-demo-project.yaml      # Project scope — limits sources, destinations, resource types
│   ├── apps/
│   │   ├── myapp-dev.yaml                # Dev application — auto-sync
│   │   ├── myapp-staging.yaml            # Staging application — auto-sync
│   │   └── myapp-prod.yaml               # Prod application — manual sync gate
│   └── appsets/
│       └── image-updater.yaml            # ArgoCD Image Updater — writes SHA tag back to this repo
│
├── k8s/
│   ├── base/
│   │   ├── deployment.yaml               # Shared deployment — Vault sidecar, probes, security context
│   │   ├── service.yaml                  # ClusterIP service
│   │   ├── ingress.yaml                  # ALB ingress — TLS via ACM, HTTP→HTTPS redirect
│   │   ├── hpa.yaml                      # Horizontal Pod Autoscaler — CPU 70% / memory 80%
│   │   ├── serviceaccount.yaml           # ServiceAccount — IRSA annotation
│   │   └── kustomization.yaml
│   ├── overlays/
│   │   ├── dev/
│   │   │   └── kustomization.yaml        # 1 replica, t3.medium, dev.myapp.example.com
│   │   ├── staging/
│   │   │   └── kustomization.yaml        # 2 replicas, t3.medium, staging.myapp.example.com
│   │   └── prod/
│   │       ├── kustomization.yaml        # 3+ replicas, m5.large, myapp.example.com
│   │       ├── rollout.yaml              # Argo Rollouts canary strategy — replaces Deployment in prod
│   │       ├── networkpolicy.yaml        # Ingress: ALB + Prometheus only. Egress: DNS + HTTPS
│   │       └── poddisruptionbudget.yaml  # minAvailable: 2 during voluntary disruptions
│   └── monitoring/
│       ├── namespace.yaml
│       ├── kustomization.yaml
│       ├── prometheus/                   # Scrape config, alert rules, RBAC, deployment
│       ├── alertmanager/                 # Routing rules, receivers (Slack + PagerDuty), deployment
│       └── grafana/                      # DORA dashboard, datasource provisioning, deployment
│
└── terraform/
    ├── modules/
    │   ├── vpc/                          # VPC, subnets, NAT Gateways, route tables
    │   ├── eks/                          # EKS cluster, node groups, OIDC, addons
    │   ├── ecr/                          # ECR repo, immutable tags, lifecycle policy
    │   ├── iam/                          # IRSA roles for app pods, Jenkins, Image Updater
    │   └── vault/                        # Vault on EKS via Helm, K8s auth, sidecar injector
    └── environments/
        ├── dev/main.tf                   # 10.0.0.0/16, t3.medium, 1–3 nodes, single NAT
        ├── staging/main.tf               # 10.1.0.0/16, t3.medium, 2–5 nodes, single NAT
        └── prod/main.tf                  # 10.2.0.0/16, m5.large, 3–10 nodes, NAT per AZ

How Deployments Work
The Full Flow
gitops-demo-app (CI repo)
  └── Jenkins builds, tests, scans, signs image
        └── pushes myapp:a3f2c1b to ECR
              └── ArgoCD Image Updater detects new tag
                    └── commits updated image ref to this repo (overlays/dev/kustomization.yaml)
                          └── ArgoCD detects diff
                                ├── dev/staging: auto-sync → apply → done
                                └── prod: waits for manual approval in ArgoCD UI
                                          └── on approval: Argo Rollouts executes canary
                                                └── 10% → analysis → 50% → analysis → 100%
                                                      ├── pass: deployment complete
                                                      └── fail: automatic rollback, no human needed
Environment Behaviour
DevStagingProdSync triggerArgoCD Image Updater commitArgoCD Image Updater commitManual approval in ArgoCD UISync modeAutomatic + selfHeal + pruneAutomatic + selfHeal + pruneManualDeploy strategyRolling updateRolling updateCanary (Argo Rollouts)Replicas123 min — 10 max (HPA)Node typet3.mediumt3.mediumm5.largeAuto-rollbackOn probe failureOn probe failureOn Prometheus metric failureNamespacedevstagingprod

Kubernetes Manifests (Kustomize)
Why Kustomize
Kustomize uses a patch model — the base directory holds everything shared, overlays hold only what differs. There is no template syntax and no risk of a typo in a {{ }} block silently rendering an empty string. Every change to a shared resource is one edit in one file.
We use Kustomize for our own application manifests and Helm for third-party tooling (ArgoCD, Vault, Prometheus). This is the right split — Helm is the distribution standard for off-the-shelf software, Kustomize is the right tool for manifests you own.
Base Manifest Decisions
Deployment — Runs as non-root user (UID 1000), read-only root filesystem, all Linux capabilities dropped. Vault sidecar injection annotations present so all environments get secrets management automatically. Liveness probe on /health, readiness probe on /health with a 5-second initial delay so the ALB does not route traffic to pods that are still starting.
ServiceAccount — Has the IRSA annotation binding it to an IAM role. AWS STS issues temporary credentials at runtime. There is no AWS_ACCESS_KEY_ID or AWS_SECRET_ACCESS_KEY anywhere in this system.
Ingress — Uses the AWS Load Balancer Controller. The ALB is provisioned automatically when this resource is applied. TLS certificate is managed by ACM — referenced by ARN annotation. HTTP traffic is redirected to HTTPS at the ALB level before it reaches any pod.
HPA — Scales on CPU (target 70%) and memory (target 80%). Min and max replicas are set per overlay.
Production Overlay Additions
Production has three resources the other environments do not:
rollout.yaml replaces the standard Deployment with an Argo Rollouts Rollout resource. The canary strategy is defined here — traffic weights, analysis template references, and bake times between steps. ArgoCD has an ignoreDifferences rule for the replica count on this resource because Argo Rollouts manages replicas directly during a canary.
networkpolicy.yaml locks down traffic at the pod level. Ingress is allowed only from the ALB controller (port 8080) and from Prometheus (port 8080 for scraping). All other ingress is denied. Egress is allowed only to DNS (port 53) and HTTPS (port 443) for AWS API calls. Nothing else can reach production pods or leave them.
poddisruptionbudget.yaml ensures at least 2 pods are available during voluntary disruptions — node drains, cluster upgrades, Terraform-initiated node group replacements. Without this, a rolling node drain could briefly take the application to zero replicas.

ArgoCD
Project Scope
The gitops-demo-project ArgoCD Project enforces boundaries around everything this pipeline deploys:

Source restriction — ArgoCD will only sync from this repository. An application definition pointing at any other source is rejected.
Destination restriction — Only the dev, staging, and prod namespaces. The monitoring namespace is managed separately.
Resource whitelist — Only specific resource types are allowed: Deployment, Rollout, Service, Ingress, HPA, ServiceAccount, NetworkPolicy, PodDisruptionBudget, ConfigMap. Anything else is blocked at the project level.
Orphaned resource monitoring — ArgoCD alerts when resources exist in the namespace that are not in Git. Prevents manual kubectl creates from going unnoticed.

Image Updater
ArgoCD Image Updater watches ECR for new tags matching the pattern ^[0-9a-f]{7}$ (7-character git SHA). When it finds one it commits the updated image reference to k8s/overlays/dev/kustomization.yaml and pushes to the main branch. ArgoCD detects the commit and syncs dev automatically.
This means the CI pipeline never writes to this repository. Jenkins has no credentials for this repo. The only writer is Image Updater — and its IAM role is scoped to ECR read-only.
Manual Sync Gate for Production
The myapp-prod application has automated: {} removed — sync is never triggered automatically. A human reviews the changes in the ArgoCD UI (which shows the exact diff between Git and cluster), approves, and clicks Sync. This creates an audit trail with a timestamp and the identity of the person who approved. After sync, Argo Rollouts takes over.

Argo Rollouts — Canary Strategy
The production Rollout uses the following canary steps:
Step 1:  Set weight 10%       → 10% of traffic goes to new version
Step 2:  Analysis (5 min)     → success_rate ≥ 99% AND p99_latency ≤ 500ms
Step 3:  Pause 2 min          → bake time
Step 4:  Set weight 50%       → half of traffic on new version
Step 5:  Analysis (5 min)     → same metrics, same thresholds
Step 6:  Pause 5 min          → bake time
Step 7:  Full rollout          → 100% traffic on new version, old pods terminated
If analysis fails at step 2 or step 5, Argo Rollouts immediately routes all traffic back to the stable version and marks the rollout as Aborted. The RolloutAborted alert fires within 1 minute. No human is required to execute the rollback.
The analysis queries Prometheus directly:
yaml# Success rate — must be ≥ 99%
sum(rate(app_requests_total{endpoint!="not_found"}[2m])) /
sum(rate(app_requests_total[endpoint!="not_found"][2m]))

# p99 latency — must be ≤ 500ms
histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket[2m])) by (le))

Terraform Infrastructure
Module Design
Each module is self-contained with its own variables.tf and outputs.tf. Modules are called from the environment entrypoints in terraform/environments/. No module contains environment-specific logic — differences between dev, staging, and prod are expressed entirely through variable values.
ModuleKey ResourcesNotesvpcVPC, 6 subnets (3 public + 3 private), 1–3 NAT Gateways, route tablesSingle NAT in dev/staging. One per AZ in prod for HA egress.eksEKS cluster, managed node groups, OIDC provider, cluster addonsAddons: coredns, kube-proxy, vpc-cni, aws-ebs-csi-driverecrECR repository, lifecycle policyImmutable tags. Lifecycle: keep last 30 tagged, delete untagged after 1 day.iam3 IRSA rolesmyapp-role (CloudWatch), jenkins-agent-role (ECR push), image-updater-role (ECR read)vaultVault Helm release, K8s auth backend, policy, roleHA (3 replicas, Raft storage) in prod. Single replica in dev/staging.
Atlantis — No Manual terraform apply
Every infrastructure change goes through a pull request. Atlantis runs terraform plan and posts the output as a PR comment. A reviewer looks at both the code and the plan. On approval the reviewer comments atlantis apply and Atlantis applies the change. The PR is merged after apply.
This means:

Every infrastructure change has a code review
Every apply has a plan that was reviewed before it ran
The Terraform state in S3 reflects exactly what was applied through the PR process
There is no "I ran this locally and forgot to commit the state" problem

Remote state is stored in S3 with DynamoDB locking. Concurrent applies are impossible.

Security
LayerMechanismWhat It PreventsAWS credentialsIRSA — STS temp tokens, no static keysCredential leaks, key rotation burdenSecretsVault sidecar injection — files, not env varsSecrets visible in kubectl describe, logs, etcdImage provenanceCosign signature verified at admissionUnsigned or tampered images runningTag immutabilityECR immutable tagsOverwriting a legitimate image tag with a malicious imageRuntimeNon-root, read-only FS, capabilities droppedContainer escape blast radiusAdmissionOPA Gatekeeper policiesMisconfigured pods reaching the clusterNetworkKubernetes NetworkPolicyCross-namespace traffic, unexpected egressInfrastructureAtlantis PR-based applyUnreviewed infrastructure changes

Monitoring
The monitoring stack lives in k8s/monitoring/ and is documented in detail in k8s/monitoring/README.md.
Summary:

Prometheus scrapes all annotated pods every 15 seconds, stores 15 days of metrics, evaluates alert rules
Grafana renders DORA metrics dashboard — deployment frequency, lead time, change failure rate, MTTR
AlertManager routes critical alerts to PagerDuty, warnings to Slack, with grouping and inhibition rules
Fluent Bit collects structured JSON logs from all pods and ships to CloudWatch Logs


Prerequisites
Before this repository can be used:

AWS account with appropriate IAM permissions
S3 bucket and DynamoDB table for Terraform remote state
Terraform applied for the target environment (terraform/environments/<env>/)
ArgoCD installed on EKS (bootstrapped separately or via Helm)
Vault installed and initialised (handled by the vault Terraform module)
This repository registered as an ArgoCD repository


Deploying Infrastructure
bashcd terraform/environments/dev    # or staging / prod
terraform init
terraform plan                   # review the plan
# In production: raise a PR, let Atlantis plan, get approval, atlantis apply
terraform apply                  # dev/staging only — never run manually in prod
Deploying ArgoCD Resources
bash# Apply the project first — it defines the scope for all apps
kubectl apply -f argocd/projects/gitops-demo-project.yaml

# Apply the applications — ArgoCD will immediately begin syncing
kubectl apply -f argocd/apps/
kubectl apply -f argocd/appsets/image-updater.yaml
Triggering a Production Deployment

A new image lands in ECR (CI pipeline completes successfully)
Image Updater commits the new SHA tag to this repo — visible in Git log
Open ArgoCD UI → myapp-prod application
Review the diff (should show only the image tag change)
Click Sync → Synchronize
Argo Rollouts begins the canary — monitor in the Argo Rollouts UI or Grafana

Rolling Back Production
bash# Option 1 — git revert (preferred — creates audit trail)
git revert HEAD
git push origin main
# ArgoCD detects the revert commit and syncs automatically (manual gate still applies)

# Option 2 — ArgoCD UI
# History tab → select previous sync → Rollback
# This creates a sync to the previous Git state

Related Repositories
RepositoryPurposegitops-demo-appApplication source code + Jenkins CI pipelinegitops-demo-deployThis repository — CD + infrastructure

Stack
CD:             ArgoCD · ArgoCD Image Updater · Argo Rollouts
Manifests:      Kustomize (app) · Helm (tooling)
Infrastructure: Terraform · Atlantis
Secrets:        HashiCorp Vault · IRSA
Registry:       Amazon ECR (immutable tags)
Signing:        Cosign (verified at admission via OPA Gatekeeper)
Networking:     AWS VPC · EKS · ALB · NetworkPolicy
Observability:  Prometheus · Grafana · AlertManager · Fluent Bit · CloudWatch