locals {
  name = "${var.project}-${var.environment}"
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = local.name
  cluster_version = var.cluster_version

  vpc_id     = var.vpc_id
  subnet_ids = var.private_subnet_ids

  # Public endpoint for kubectl access from CI and developers.
  # Private endpoint for node-to-control-plane communication inside the VPC.
  cluster_endpoint_public_access  = true
  cluster_endpoint_private_access = true

  # OIDC provider is required for IRSA — IAM Roles for Service Accounts.
  # Without this, pods cannot assume IAM roles.
  enable_irsa = true

  # Managed node groups — AWS handles node lifecycle.
  # Karpenter is also installed for dynamic node provisioning.
  eks_managed_node_groups = {
    default = {
      instance_types = var.node_instance_types
      min_size       = var.node_min_size
      max_size       = var.node_max_size
      desired_size   = var.node_desired_size

      # Nodes run in private subnets — not publicly reachable.
      subnet_ids = var.private_subnet_ids

      labels = {
        environment = var.environment
      }
    }
  }

  # Cluster addons — managed by AWS, automatically updated.
  cluster_addons = {
    coredns    = { most_recent = true }
    kube-proxy = { most_recent = true }
    vpc-cni    = { most_recent = true }
    # EBS CSI driver for persistent volume support.
    aws-ebs-csi-driver = { most_recent = true }
  }

  # Control plane logs sent to CloudWatch.
  cluster_enabled_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  tags = var.tags
}
