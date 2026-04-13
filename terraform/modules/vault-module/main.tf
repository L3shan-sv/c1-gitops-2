# terraform/modules/vault/main.tf
#
# Vault on EKS — Helm release + KMS auto-unseal key + IRSA role.
# Called from terraform/environments/<env>/main.tf.

terraform {
  required_providers {
    aws        = { source = "hashicorp/aws",        version = ">= 5.0" }
    helm       = { source = "hashicorp/helm",       version = ">= 2.12" }
    kubernetes = { source = "hashicorp/kubernetes", version = ">= 2.27" }
  }
}

# ── KMS key for auto-unseal ────────────────────────────────────────────────
resource "aws_kms_key" "vault_unseal" {
  # Dev environments skip KMS — Shamir unseal is used instead.
  count = var.environment == "dev" ? 0 : 1

  description             = "Vault auto-unseal key — ${var.environment}"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  tags = {
    Environment = var.environment
    ManagedBy   = "terraform"
    Purpose     = "vault-unseal"
  }
}

resource "aws_kms_alias" "vault_unseal" {
  count         = var.environment == "dev" ? 0 : 1
  name          = "alias/vault-unseal-${var.environment}"
  target_key_id = aws_kms_key.vault_unseal[0].key_id
}

# ── IAM policy for KMS unseal ─────────────────────────────────────────────
data "aws_iam_policy_document" "vault_kms" {
  count = var.environment == "dev" ? 0 : 1

  statement {
    sid    = "VaultKMSUnseal"
    effect = "Allow"
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:DescribeKey",
    ]
    resources = [aws_kms_key.vault_unseal[0].arn]
  }
}

resource "aws_iam_policy" "vault_kms" {
  count       = var.environment == "dev" ? 0 : 1
  name        = "vault-kms-unseal-${var.environment}"
  description = "Allows Vault pods to use KMS for auto-unseal"
  policy      = data.aws_iam_policy_document.vault_kms[0].json
}

# ── IRSA trust policy ─────────────────────────────────────────────────────
# Scoped to the vault ServiceAccount in the vault namespace only.
data "aws_iam_policy_document" "vault_irsa_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:sub"
      values   = ["system:serviceaccount:vault:vault"]
    }

    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "vault" {
  name               = "vault-irsa-${var.environment}"
  assume_role_policy = data.aws_iam_policy_document.vault_irsa_trust.json

  tags = {
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

resource "aws_iam_role_policy_attachment" "vault_kms" {
  count      = var.environment == "dev" ? 0 : 1
  role       = aws_iam_role.vault.name
  policy_arn = aws_iam_policy.vault_kms[0].arn
}

# ── Helm release ──────────────────────────────────────────────────────────
resource "helm_release" "vault" {
  name             = "vault"
  repository       = "https://helm.releases.hashicorp.com"
  chart            = "vault"
  version          = "0.28.0"
  namespace        = "vault"
  create_namespace = true
  wait             = true
  timeout          = 600

  values = [templatefile("${path.module}/helm-values.yaml.tpl", {
    environment = var.environment
    kms_key_id  = var.environment != "dev" ? aws_kms_key.vault_unseal[0].key_id : ""
    aws_region  = var.aws_region
    replicas    = var.replicas
  })]
}

# ── Annotate Vault ServiceAccount with IRSA role ARN ─────────────────────
resource "kubernetes_annotations" "vault_sa_irsa" {
  api_version = "v1"
  kind        = "ServiceAccount"
  metadata {
    name      = "vault"
    namespace = "vault"
  }
  annotations = {
    "eks.amazonaws.com/role-arn" = aws_iam_role.vault.arn
  }

  depends_on = [helm_release.vault]
}
