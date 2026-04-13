# terraform/modules/vault/outputs.tf

output "vault_role_arn" {
  description = "IAM role ARN for Vault pods (IRSA)"
  value       = aws_iam_role.vault.arn
}

output "kms_key_id" {
  description = "KMS key ID used for auto-unseal. Empty string in dev (Shamir used instead)"
  value       = var.environment != "dev" ? aws_kms_key.vault_unseal[0].key_id : ""
}

output "kms_key_arn" {
  description = "KMS key ARN used for auto-unseal. Empty string in dev"
  value       = var.environment != "dev" ? aws_kms_key.vault_unseal[0].arn : ""
}
