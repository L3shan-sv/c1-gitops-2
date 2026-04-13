#!/usr/bin/env bash
# bootstrap/scripts/02-image-updater-secret.sh
#
# Provisions the Git credentials that ArgoCD Image Updater needs to commit
# updated image tags back to this repository.
#
# Image Updater needs TWO sets of credentials:
#   1. ECR credentials — handled automatically via IRSA (the IAM role created
#      by terraform/modules/iam has ECR read-only permissions). No secret needed.
#   2. Git write credentials — needed to commit the updated kustomization.yaml
#      back to the deploy repo. This script provisions that secret.
#
# Supported Git auth methods (choose one):
#   - GitHub App (recommended for organisations — no expiry, fine-grained scope)
#   - Personal Access Token / Deploy Key (simpler for individuals)
#
# Usage:
#   GIT_METHOD=github-app \
#   GH_APP_ID=123456 \
#   GH_APP_INSTALLATION_ID=78901234 \
#   GH_APP_PRIVATE_KEY_PATH=/path/to/private-key.pem \
#   ./bootstrap/scripts/02-image-updater-secret.sh
#
#   GIT_METHOD=token \
#   GIT_TOKEN=ghp_xxxxxxxxxxxxxxxxxxxx \
#   GIT_REPO_URL=https://github.com/your-org/gitops-demo-deploy \
#   ./bootstrap/scripts/02-image-updater-secret.sh

set -euo pipefail

GIT_METHOD="${GIT_METHOD:?Set GIT_METHOD=github-app|token}"
SECRET_NAME="argocd-image-updater-secret"
NAMESPACE="argocd"

# Delete existing secret if it exists (idempotent re-run)
kubectl delete secret "$SECRET_NAME" -n "$NAMESPACE" --ignore-not-found

case "$GIT_METHOD" in

  github-app)
    GH_APP_ID="${GH_APP_ID:?Set GH_APP_ID}"
    GH_APP_INSTALLATION_ID="${GH_APP_INSTALLATION_ID:?Set GH_APP_INSTALLATION_ID}"
    GH_APP_PRIVATE_KEY_PATH="${GH_APP_PRIVATE_KEY_PATH:?Set GH_APP_PRIVATE_KEY_PATH}"

    [[ -f "$GH_APP_PRIVATE_KEY_PATH" ]] || { echo "Private key not found: $GH_APP_PRIVATE_KEY_PATH"; exit 1; }

    kubectl create secret generic "$SECRET_NAME" \
      --namespace "$NAMESPACE" \
      --from-literal=githubAppID="$GH_APP_ID" \
      --from-literal=githubAppInstallationID="$GH_APP_INSTALLATION_ID" \
      --from-file=githubAppPrivateKey="$GH_APP_PRIVATE_KEY_PATH"

    echo "Created $SECRET_NAME (GitHub App method) in namespace $NAMESPACE"
    echo ""
    echo "GitHub App setup checklist:"
    echo "  1. App must have Read+Write access to Contents on this repo only"
    echo "  2. App must NOT have any other permissions (principle of least privilege)"
    echo "  3. Rotate the private key annually or on any team member departure"
    ;;

  token)
    GIT_TOKEN="${GIT_TOKEN:?Set GIT_TOKEN}"
    GIT_REPO_URL="${GIT_REPO_URL:?Set GIT_REPO_URL}"

    kubectl create secret generic "$SECRET_NAME" \
      --namespace "$NAMESPACE" \
      --from-literal=username=argocd-image-updater \
      --from-literal=password="$GIT_TOKEN"

    # Also patch the ArgoCD repo registration to use this secret
    # (Image Updater reads credentials from the ArgoCD repository secret)
    kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: gitops-demo-deploy-repo
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
type: Opaque
stringData:
  type: git
  url: "$GIT_REPO_URL"
  username: argocd-image-updater
  password: "$GIT_TOKEN"
EOF

    echo "Created $SECRET_NAME (token method) in namespace $NAMESPACE"
    echo ""
    echo "Token setup checklist:"
    echo "  1. Use a fine-grained PAT scoped to THIS repo only (not classic tokens)"
    echo "  2. Grant Contents: Read+Write only — nothing else"
    echo "  3. Set a 90-day expiry and calendar reminder to rotate it"
    echo "  4. Token is now in cluster etcd — ensure etcd encryption at rest is enabled"
    ;;

  *)
    echo "Unknown GIT_METHOD: $GIT_METHOD. Use github-app or token."
    exit 1
    ;;
esac

# Label the secret so ArgoCD Image Updater can discover it
kubectl label secret "$SECRET_NAME" \
  --namespace "$NAMESPACE" \
  "app.kubernetes.io/managed-by=gitops-demo-bootstrap" \
  --overwrite

echo ""
echo "Verify Image Updater can reach Git by checking its logs after bootstrap:"
echo "  kubectl logs -n argocd -l app.kubernetes.io/name=argocd-image-updater --tail=50"