provider "aws" {
  region = "ap-south-1"

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
  region       = "ap-south-1"
}