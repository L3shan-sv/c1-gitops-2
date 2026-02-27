locals {
  name = "${var.project}-${var.environment}"
}

# ── App pod IAM role ──────────────────────────────────────────────────────────
# Bound to the myapp ServiceAccount via IRSA.
# Grants only what the application needs — S3 read for config, CloudWatch logs.
module "myapp_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name = "${local.name}-myapp"

  oidc_providers = {
    main = {
      provider_arn               = var.oidc_provider_arn
      namespace_service_accounts = [
        "dev:myapp",
        "staging:myapp",
        "prod:myapp"
      ]
    }
  }

  role_policy_arns = {
    cloudwatch = "arn:aws:iam::aws:policy/CloudWatchLogsFullAccess"
  }
}

# ── Jenkins agent IAM role ────────────────────────────────────────────────────
# Grants ECR push and pull. Nothing more.
module "jenkins_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name = "${local.name}-jenkins-agent"

  oidc_providers = {
    main = {
      provider_arn               = var.oidc_provider_arn
      namespace_service_accounts = ["jenkins:jenkins-agent"]
    }
  }

  role_policy_arns = {
    ecr = aws_iam_policy.ecr_push.arn
  }
}

resource "aws_iam_policy" "ecr_push" {
  name = "${local.name}-ecr-push"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:PutImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage"
        ]
        Resource = "*"
      }
    ]
  })
}

# ── ArgoCD Image Updater IAM role ─────────────────────────────────────────────
module "argocd_image_updater_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name = "${local.name}-argocd-image-updater"

  oidc_providers = {
    main = {
      provider_arn               = var.oidc_provider_arn
      namespace_service_accounts = ["argocd:argocd-image-updater"]
    }
  }

  role_policy_arns = {
    ecr_readonly = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  }
}
