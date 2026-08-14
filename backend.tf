terraform {
  required_version = ">= 1.10.0"

  # Stores terraform state in S3 instead of local disk.
  # use_lockfile -> native S3 locking (TF 1.10+), no DynamoDB table needed.
  # Note: backend block can't use variables, values must be hardcoded here.
  backend "s3" {
    bucket       = "eks-observable-platform-tfstate-krishna756808"
    key          = "eks-observable-platform/terraform.tfstate"
    region       = "ap-south-2"
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