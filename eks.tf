# ---------- IAM ----------

# eks is managed but still creates ENIs/SGs/LBs in our vpc, so it needs a role from us
resource "aws_iam_role" "eks_cluster" {
  name = "${local.project_name}-cluster-role"

  # only the eks service can assume this (same as "EKS - Cluster" use case in the console)
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "eks.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# workers are plain ec2 instances, so this one trusts ec2 not eks
resource "aws_iam_role" "eks_nodes" {
  name = "${local.project_name}-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

# all three are needed - joining the cluster, pod networking, pulling images
resource "aws_iam_role_policy_attachment" "node_worker_policy" {
  role       = aws_iam_role.eks_nodes.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "node_cni_policy" {
  role       = aws_iam_role.eks_nodes.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "node_ecr_policy" {
  role       = aws_iam_role.eks_nodes.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# ---------- Cluster ----------

resource "aws_eks_cluster" "main" {
  name     = local.project_name
  role_arn = aws_iam_role.eks_cluster.arn

  access_config {
    authentication_mode = "API_AND_CONFIG_MAP"

    # already true from cluster creation - this is what gives the creating
    # IAM user cluster-admin. omitting it reads as "remove it", which forces
    # a full cluster replacement.
    bootstrap_cluster_creator_admin_permissions = true
  }

  vpc_config {
    # both subnets, eks wants 2 AZs minimum for the control plane
    subnet_ids = aws_subnet.public[*].id
  }

  # terraform doesnt see this dependency on its own and the cluster can fail if the role has no policy attached yet.
  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_policy
  ]
}

# ---------- Node group ----------

resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${local.project_name}-nodes"
  node_role_arn   = aws_iam_role.eks_nodes.arn
  subnet_ids      = [aws_subnet.public[0].id] # single AZ to save cost

  instance_types = ["m7i-flex.large"]
  capacity_type  = "ON_DEMAND"

  scaling_config {
    desired_size = 1
    min_size     = 1
    max_size     = 2 # max 2 so i can drain a node later for testing
  }

  depends_on = [
    aws_iam_role_policy_attachment.node_worker_policy,
    aws_iam_role_policy_attachment.node_cni_policy,
    aws_iam_role_policy_attachment.node_ecr_policy
  ]
}