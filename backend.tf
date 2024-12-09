provider "aws" {
  region              = var.region
  allowed_account_ids = [var.aws_account_id]
  profile             = var.aws_cli_profile
}

provider "aws" {
  region  = "us-east-1"
  alias   = "virginia"
  profile = var.aws_cli_profile
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--profile", "mm"]
    }
  }
}

provider "kubectl" {
  apply_retry_count      = 5
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  load_config_file       = false

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--profile", "mm"]
  }
}

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }

    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14"
    }
  }

  backend "s3" {
    bucket         = "mm-tf-shared-state-files"
    key            = "terraform/eks-karpenter/terraform.tfstate"
    region         = "eu-west-1"
    dynamodb_table = "mm-tf-lock-table"
    profile        = "mm"
  }
}
