terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.80"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.17"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Recommended for real use: remote state with native S3 locking (Terraform >= 1.10).
  # backend "s3" {
  #   bucket       = "my-terraform-state-bucket"
  #   key          = "stateful-node-on-eks/terraform.tfstate"
  #   region       = "us-east-2"
  #   use_lockfile = true
  #   encrypt      = true
  # }
}
