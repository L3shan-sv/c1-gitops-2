terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws   = { source = "hashicorp/aws"   version = "~> 5.0" }
    helm  = { source = "hashicorp/helm"  version = "~> 2.0" }
    vault = { source = "hashicorp/vault" version = "~> 3.0" }
  }

  backend "s3" {
    bucket         = "gitops-demo-terraform-state"
    key            = "dev/terraform.tfstate"
    region         = "ap-southest-2"
    encrypt        = true
    dynamodb_table = "gitops-demo-terraform-locks"
  }
}

provider "aws" {
  region = var.aws_region
  default_tags { tags = local.tags }
}

locals {
  tags = {
    Project     = "gitops-demo"
    Environment = "dev"
    ManagedBy   = "terraform"
  }
}

module "vpc" {
  source      = "../../modules/vpc"
  project     = "gitops-demo"
  environment = "dev"
  vpc_cidr    = "10.0.0.0/16"
  tags        = local.tags
}

module "eks" {
  source              = "../../modules/eks"
  project             = "gitops-demo"
  environment         = "dev"
  vpc_id              = module.vpc.vpc_id
  private_subnet_ids  = module.vpc.private_subnet_ids
  node_instance_types = ["t3.medium"]
  node_min_size       = 1
  node_max_size       = 3
  node_desired_size   = 1
  tags                = local.tags
}

module "iam" {
  source            = "../../modules/iam"
  project           = "gitops-demo"
  environment       = "dev"
  oidc_provider_arn = module.eks.oidc_provider_arn
  tags              = local.tags
}

variable "aws_region" {
  type    = string
  default = "ap-southest-2"
}
