# terraform/modules/vault/variables.tf

variable "environment" {
  description = "Environment name: dev, staging, or prod"
  type        = string
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be dev, staging, or prod"
  }
}

variable "aws_region" {
  description = "AWS region where the EKS cluster runs"
  type        = string
}

variable "oidc_provider_arn" {
  description = "ARN of the EKS cluster OIDC provider (from eks module output)"
  type        = string
}

variable "oidc_provider_url" {
  description = "URL of the EKS cluster OIDC provider without https:// prefix"
  type        = string
}

variable "replicas" {
  description = "Number of Vault server replicas. Use 1 for dev, 3 for staging/prod"
  type        = number
  default     = 1
}
