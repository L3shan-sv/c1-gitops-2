locals {
  name = "${var.project}-${var.environment}"

  # Spread across 3 AZs for high availability.
  # EKS requires at least 2 AZs. 3 is production standard.
  azs = slice(data.aws_availability_zones.available.names, 0, 3)
}

data "aws_availability_zones" "available" {
  state = "available"
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = local.name
  cidr = var.vpc_cidr

  azs             = local.azs
  private_subnets = [for k, v in local.azs : cidrsubnet(var.vpc_cidr, 4, k)]
  public_subnets  = [for k, v in local.azs : cidrsubnet(var.vpc_cidr, 8, k + 48)]

  # NAT Gateway allows private subnet resources (EKS nodes) to reach
  # the internet for ECR pulls and AWS API calls without being publicly reachable.
  enable_nat_gateway     = true
  single_nat_gateway     = var.environment != "prod" # Save cost in non-prod
  enable_dns_hostnames   = true
  enable_dns_support     = true

  # Tags required by EKS and the AWS Load Balancer Controller
  # to discover which subnets to use for load balancers.
  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"            = 1
    "karpenter.sh/discovery"                     = local.name
  }

  tags = var.tags
}
