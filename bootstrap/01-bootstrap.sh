#!/usr/bin/env bash
# bootstrap/scripts/01-bootstrap.sh
#
# Bootstraps a new environment from zero to a running ArgoCD that manages itself.
# Run this once per environment. After it completes, all further changes go
# through Git — never run this script again unless rebuilding from scratch.
#
# Usage:
#   ENV=dev AWS_REGION=eu-west-1 CLUSTER_NAME=gitops-demo-dev ./bootstrap/scripts/01-bootstrap.sh
#
# Prerequisites:
#   - aws CLI configured with admin-level credentials for the target account
#   - kubectl, helm, terraform >= 1.7 installed locally
#   - Terraform state backend (S3 + DynamoDB) already exists
#     (create it once with: aws s3 mb s3://gitops-demo-tfstate-<account_id>)

set -euo pipefail

ENV="${ENV:?Set ENV=dev|staging|prod}"
AWS_REGION="${AWS_REGION:?Set AWS_REGION}"
CLUSTER_NAME="${CLUSTER_NAME:?Set CLUSTER_NAME}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "==> Bootstrapping environment: $ENV  cluster: $CLUSTER_NAME  account: $ACCOUNT_ID"

# ── Step 1: Terraform ────────────────────────────────────────────────────────
echo ""
echo "── Step 1: Terraform apply ($ENV) ──────────────────────────────────────"
if [[ "$ENV" == "prod" ]]; then
  echo "PROD: raise a PR and use Atlantis. Do not run terraform apply manually."
  echo "Skipping Terraform for prod."
else
  pushd "terraform/environments/$ENV"
  terraform init -upgrade
  terraform plan -out=tfplan
  echo ""
  read -rp "Review the plan above. Apply? [y/N] " confirm
  [[ "$confirm" == "y" ]] || { echo "Aborted."; exit 1; }
  terraform apply tfplan
  popd
fi

# ── Step 2: kubeconfig ───────────────────────────────────────────────────────
echo ""
echo "── Step 2: Configure kubeconfig ────────────────────────────────────────"
aws eks update-kubeconfig \
  --name "$CLUSTER_NAME" \
  --region "$AWS_REGION" \
  --alias "$CLUSTER_NAME"

kubectl config use-context "$CLUSTER_NAME"

echo "Waiting for nodes to be Ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=300s

# ── Step 3: Vault unseal ─────────────────────────────────────────────────────
echo ""
echo "── Step 3: Vault init & unseal ─────────────────────────────────────────"
echo "Vault is installed by Terraform via Helm. Checking status..."

VAULT_POD=$(kubectl get pods -n vault -l app.kubernetes.io/name=vault \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

if [[ -z "$VAULT_POD" ]]; then
  echo "ERROR: No Vault pod found in namespace 'vault'. Did Terraform apply succeed?"
  exit 1
fi

VAULT_STATUS=$(kubectl exec -n vault "$VAULT_POD" -- vault status -format=json 2>/dev/null \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('initialized','unknown'))" \
  || echo "unknown")

if [[ "$VAULT_STATUS" == "False" || "$VAULT_STATUS" == "false" ]]; then
  echo "Vault is not initialised. Initialising now..."
  kubectl exec -n vault "$VAULT_POD" -- vault operator init \
    -key-shares=5 \
    -key-threshold=3 \
    -format=json > "/tmp/vault-init-$ENV.json"
  echo ""
  echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  echo "CRITICAL: Vault init keys saved to /tmp/vault-init-$ENV.json"
  echo "Move this file to your secure password manager NOW."
  echo "Delete /tmp/vault-init-$ENV.json immediately after."
  echo "In staging/prod these keys are not needed — KMS auto-unseal handles it."
  echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  echo ""
  # Auto-unseal dev using the generated unseal keys (first 3 of 5)
  if [[ "$ENV" == "dev" ]]; then
    UNSEAL_KEYS=$(python3 -c "
import json
d = json.load(open('/tmp/vault-init-$ENV.json'))
for k in d['unseal_keys_b64'][:3]:
    print(k)
")
    while IFS= read -r key; do
      kubectl exec -n vault "$VAULT_POD" -- vault operator unseal "$key"
    done <<< "$UNSEAL_KEYS"
    echo "Vault unsealed (dev — manual unseal)."
  else
    echo "Staging/prod use KMS auto-unseal — see terraform/modules/vault/main.tf."
    echo "Vault will unseal automatically after pod restarts."
  fi
else
  echo "Vault already initialised. Skipping."
fi

# ── Step 4: Platform tools via Helm ─────────────────────────────────────────
echo ""
echo "── Step 4: Install platform tools ─────────────────────────────────────"

VPC_ID=$(cd "terraform/environments/$ENV" && terraform output -raw vpc_id 2>/dev/null || echo "")
ALB_ROLE_ARN=$(cd "terraform/environments/$ENV" && terraform output -raw alb_controller_role_arn 2>/dev/null || echo "")

helm repo add argo https://argoproj.github.io/argo-helm
helm repo add eks https://aws.github.io/eks-charts
helm repo add gatekeeper https://open-policy-agent.github.io/gatekeeper/charts
helm repo update

# AWS Load Balancer Controller — required before any Ingress resources work
echo "Installing AWS Load Balancer Controller..."
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  --namespace kube-system \
  --values bootstrap/helm-values/aws-load-balancer-controller-values.yaml \
  --set clusterName="$CLUSTER_NAME" \
  --set region="$AWS_REGION" \
  --set vpcId="$VPC_ID" \
  --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=$ALB_ROLE_ARN" \
  --wait

# OPA Gatekeeper — admission webhooks for Cosign image verification
echo "Installing OPA Gatekeeper..."
helm upgrade --install gatekeeper gatekeeper/gatekeeper \
  --namespace gatekeeper-system --create-namespace \
  --values bootstrap/helm-values/gatekeeper-values.yaml \
  --wait

# Apply Cosign + policy manifests now that Gatekeeper is Ready
echo "Applying admission policies..."
kubectl apply -k k8s/policies/

# Argo Rollouts controller
echo "Installing Argo Rollouts..."
helm upgrade --install argo-rollouts argo/argo-rollouts \
  --namespace argo-rollouts --create-namespace \
  --values bootstrap/helm-values/argo-rollouts-values.yaml \
  --wait

# ArgoCD — installed last so it can immediately manage everything above
echo "Installing ArgoCD..."
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd --create-namespace \
  --values bootstrap/helm-values/argocd-values.yaml \
  --wait

# ── Step 5: ArgoCD bootstrap ─────────────────────────────────────────────────
echo ""
echo "── Step 5: Bootstrap ArgoCD applications ───────────────────────────────"
echo "Registering Image Updater Git credentials..."
bash bootstrap/scripts/02-image-updater-secret.sh

kubectl apply -f argocd/projects/gitops-demo-project.yaml
kubectl apply -f argocd/apps/
kubectl apply -f argocd/appsets/image-updater.yaml

# ── Step 6: Verify ───────────────────────────────────────────────────────────
echo ""
echo "── Step 6: Health check ────────────────────────────────────────────────"
echo "Waiting for ArgoCD applications to sync (up to 5 min)..."
sleep 30
kubectl get pods -n argocd
echo ""
echo "Run the following to watch sync status:"
echo "  watch argocd app list"
echo ""
echo "Bootstrap complete for environment: $ENV"
echo "Dev and staging will auto-sync. Prod requires manual approval in the ArgoCD UI."