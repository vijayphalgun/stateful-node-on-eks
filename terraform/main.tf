data "aws_availability_zones" "available" {
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  name = var.cluster_name
  azs  = slice(data.aws_availability_zones.available.names, 0, 3)

  tags = {
    Project    = local.name
    ManagedBy  = "terraform"
    Repository = "stateful-node-on-eks"
  }
}

################################################################################
# Network
################################################################################

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.16"

  name = local.name
  cidr = var.vpc_cidr
  azs  = local.azs

  private_subnets = [for i, az in local.azs : cidrsubnet(var.vpc_cidr, 4, i)]
  public_subnets  = [for i, az in local.azs : cidrsubnet(var.vpc_cidr, 8, i + 48)]

  # Blockchain clients keep long-lived outbound connections to many peers,
  # so egress goes through NAT. One gateway keeps the sandbox cheap.
  enable_nat_gateway = true
  single_nat_gateway = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }
}

################################################################################
# EBS CSI driver identity (Pod Identity, scoped to the controller service account)
################################################################################

data "aws_iam_policy_document" "pod_identity_trust" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ebs_csi" {
  name               = "${local.name}-ebs-csi"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

################################################################################
# EKS: a general node group for platform add-ons, and a dedicated, tainted,
# single-AZ node group that only blockchain nodes can schedule onto.
################################################################################

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.31"

  cluster_name    = local.name
  cluster_version = var.kubernetes_version

  cluster_endpoint_public_access       = true
  cluster_endpoint_public_access_cidrs = var.api_allowed_cidrs

  enable_cluster_creator_admin_permissions = true

  cluster_addons = {
    coredns    = {}
    kube-proxy = {}
    vpc-cni = {
      before_compute = true
    }
    eks-pod-identity-agent = {
      before_compute = true
    }
    aws-ebs-csi-driver = {
      pod_identity_association = [{
        role_arn        = aws_iam_role.ebs_csi.arn
        service_account = "ebs-csi-controller-sa"
      }]
    }
  }

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  eks_managed_node_groups = {
    general = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = var.system_instance_types

      min_size     = 2
      max_size     = 3
      desired_size = 2

      labels = {
        "node-role" = "general"
      }
    }

    blockchain = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = var.node_instance_types

      # One AZ on purpose: the node's EBS volumes live in this AZ, and a
      # replacement node must come up in the same AZ to reattach them.
      subnet_ids = [module.vpc.private_subnets[var.node_az_index]]

      min_size     = 1
      max_size     = 2
      desired_size = 1

      labels = {
        "node-role" = "blockchain"
      }

      taints = {
        dedicated = {
          key    = "dedicated"
          value  = "blockchain"
          effect = "NO_SCHEDULE"
        }
      }
    }
  }
}
