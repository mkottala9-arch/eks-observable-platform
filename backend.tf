terraform {
  required_version = ">= 1.9.0"

  backend "s3" {
    bucket       = "eks-observable-platform-tfstate-krishna767371"
    key          = "eks-observable-platform/terraform.tfstate"
    region       = "ap-south-1"
    encrypt      = true
    use_lockfile = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}