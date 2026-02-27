terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws   = { source = "hashicorp/aws"   version = "~> 5.0" }
    helm  = { source = "hashicorp/helm"  version = "~> 2.0" }
    vault = { source = "hashicorp/vault" version = "~> 3.0" }
  }

  # Remote state in S3 — never store state locally.
  # State locking via DynamoDB prevents concurrent applies.
  backend "s3" {
    bucket         = "gitops-demo-terraform-state"
    key            = "prod/terraform.tfstate"
    region         = "ap-southest-2"
    encrypt        = true
    dynamodb_table = "gitops-demo-terraform-locks"
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.tags
  }
}

locals {
  tags = {
    Project     = "gitops-demo"
    Environment = "prod"
    ManagedBy   = "terraform"
    Repo        = "gitops-demo-deploy"
  }
}

module "vpc" {
  source      = "../../modules/vpc"
  project     = "gitops-demo"
  environment = "prod"
  vpc_cidr    = "10.2.0.0/16"
  tags        = local.tags
}

module "eks" {
  source               = "../../modules/eks"
  project              = "gitops-demo"
  environment          = "prod"
  cluster_version      = "1.29"
  vpc_id               = module.vpc.vpc_id
  private_subnet_ids   = module.vpc.private_subnet_ids
  node_instance_types  = ["m5.large"]
  node_min_size        = 3
  node_max_size        = 10
  node_desired_size    = 3
  tags                 = local.tags
}

module "ecr" {
  source  = "../../modules/ecr"
  project = "gitops-demo"
  tags    = local.tags
}

module "iam" {
  source           = "../../modules/iam"
  project          = "gitops-demo"
  environment      = "prod"
  oidc_provider_arn = module.eks.oidc_provider_arn
  tags             = local.tags
}

module "vault" {
  source             = "../../modules/vault"
  environment        = "prod"
  vault_irsa_role_arn = module.iam.myapp_role_arn
  cluster_endpoint   = module.eks.cluster_endpoint
  cluster_ca_cert    = module.eks.cluster_certificate_authority_data
}

variable "aws_region" {
  type    = string
  default = "ap-southest-2"
}
