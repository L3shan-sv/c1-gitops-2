# Bootstrap

This directory contains everything needed to bring a new environment from zero
to a running, self-managing GitOps cluster. Run it once per environment. After
bootstrap completes, all further changes go through Git — never run these
scripts again unless rebuilding from scratch.

## Prerequisites

Before running bootstrap you need:

| Requirement | How to create |
|---|---|
| AWS account + admin IAM credentials | Manually, via your org's account vending |
| S3 bucket for Terraform state | `aws s3 mb s3://gitops-demo-tfstate-<account_id>` |
| DynamoDB table for state lock | `aws dynamodb create-table --table-name gitops-demo-tflock --attribute-definitions AttributeName=LockID,AttributeType=S --key-schema AttributeName=LockID,KeyType=HASH --billing-mode PAY_PER_REQUEST` |
| Local tools | `aws`, `kubectl`, `helm >= 3.14`, `terraform >= 1.7`, `argocd` CLI |
| Git credentials for Image Updater | GitHub App (preferred) or fine-grained PAT — see Step 4 below |

## Directory structure

```
bootstrap/
├── helm-values/
│   ├── argocd-values.yaml                  # ArgoCD Helm values
│   ├── argo-rollouts-values.yaml           # Argo Rollouts Helm values
│   ├── gatekeeper-values.yaml              # OPA Gatekeeper Helm values
│   └── aws-load-balancer-controller-values.yaml
└── scripts/
    ├── 01-bootstrap.sh                     # Main bootstrap script (run this)
    └── 02-image-updater-secret.sh          # Git credentials for Image Updater
```

## Step-by-step

### Step 1 — State backend (once per AWS account)

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION=eu-west-1

aws s3 mb s3://gitops-demo-tfstate-${ACCOUNT_ID} --region $REGION
aws s3api put-bucket-versioning \
  --bucket gitops-demo-tfstate-${ACCOUNT_ID} \
  --versioning-configuration Status=Enabled

aws dynamodb create-table \
  --table-name gitops-demo-tflock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region $REGION
```

### Step 2 — Configure backend in each environment

Edit `terraform/environments/<env>/main.tf` and set the actual bucket name:

```hcl
terraform {
  backend "s3" {
    bucket         = "gitops-demo-tfstate-<ACCOUNT_ID>"
    key            = "<env>/terraform.tfstate"
    region         = "eu-west-1"
    dynamodb_table = "gitops-demo-tflock"
    encrypt        = true
  }
}
```

### Step 3 — Prepare Image Updater Git credentials

Image Updater needs write access to this repo to commit updated image tags.
Two options:

**Option A — GitHub App (recommended for teams)**
1. Create a GitHub App in your org (Settings → Developer settings → GitHub Apps)
2. Grant it `Contents: Read+Write` on this repository only
3. Generate and download a private key
4. Note the App ID and Installation ID

**Option B — Fine-grained PAT (simpler for individuals)**
1. GitHub → Settings → Developer settings → Personal access tokens → Fine-grained
2. Scope to this repository only, `Contents: Read+Write`, 90-day expiry
3. Copy the token

### Step 4 — Run bootstrap

```bash
# Dev
ENV=dev \
AWS_REGION=eu-west-1 \
CLUSTER_NAME=gitops-demo-dev \
GIT_METHOD=github-app \
GH_APP_ID=123456 \
GH_APP_INSTALLATION_ID=78901234 \
GH_APP_PRIVATE_KEY_PATH=~/keys/gitops-app.pem \
./bootstrap/scripts/01-bootstrap.sh

# Staging / Prod — same command with ENV=staging or ENV=prod
# Prod will skip the terraform apply step and remind you to use Atlantis.
```

### Step 5 — Post-bootstrap checklist

- [ ] Move `/tmp/vault-init-<env>.json` to your password manager and delete it
- [ ] Confirm all ArgoCD apps show `Synced/Healthy`: `argocd app list`
- [ ] Verify Cosign constraint is enforcing: `kubectl get constraints`
- [ ] Update `k8s/policies/cosign-constraint.yaml` with your real public key and ECR prefix
- [ ] Set individual ArgoCD accounts (not shared `admin`) for the audit trail

## Vault unsealing

| Environment | Unseal method | Configured by |
|---|---|---|
| dev | Shamir (manual) | `01-bootstrap.sh` reads keys from vault init output |
| staging | AWS KMS auto-unseal | `terraform/modules/vault/main.tf` — KMS key created automatically |
| prod | AWS KMS auto-unseal | Same — one KMS key per environment |

In staging/prod, Vault pods unseal themselves on restart using the KMS key.
No human intervention needed. The KMS key ARN is in `terraform output kms_key_arn`.

## Re-running bootstrap

The scripts are idempotent — Helm uses `upgrade --install`, kubectl `apply` is
declarative, and the secret script deletes and recreates. Safe to re-run if
something fails partway through.

## Teardown

```bash
# Remove ArgoCD apps first (so ArgoCD doesn't fight Terraform)
kubectl delete -f argocd/apps/
kubectl delete -f argocd/projects/

# Then destroy infrastructure
cd terraform/environments/<env>
terraform destroy
```