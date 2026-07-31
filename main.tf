provider "aws" {
  region = "ap-south-2"

  # everything gets tagged, makes cost tracking and post-destroy checks easier
  default_tags {
    tags = {
      Project     = "eks-observable-platform"
      ManagedBy   = "terraform"
      Environment = "learning"
    }
  }
}

locals {
  project_name = "eks-observable-platform"
  region       = "ap-south-2"
}