provider "aws" {
  region = "ap-south-1"

  # These tags get applied to every resource terraform creates here.
  # Useful for filtering in Cost Explorer and verifying cleanup after destroy.
  default_tags {
    tags = {
      Project     = "eks-observable-platform"
      ManagedBy   = "terraform"
      Environment = "learning"
    }
  }
}

# Common values reused across files - change once, applies everywhere
locals {
  project_name = "eks-observable-platform"
  region       = "ap-south-1"
}