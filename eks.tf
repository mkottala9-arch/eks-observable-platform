# ---------- IAM ----------

# control plane role - EKS is managed but it still creates ENIs, SGs, LBs
# inside our vpc, so it needs permissions from us
resource "aws_iam_role" "eks_cluster" {
  name = "${local.project_name}-cluster-role"

  # trust policy - only eks service can assume this
  # (same as selecting "EKS - Cluster" use case in console)
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

# node role - workers are just ec2 machines, so trust is ec2 not eks
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

# WorkerNode -> join cluster, CNI -> pod networking, ECR -> pull images
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

# control plane only, no nodes from this. aws manages apiserver/etcd,
# HA across AZs, we never see those machines.
resource "aws_eks_cluster" "main" {
  name     = local.project_name
  role_arn = aws_iam_role.eks_cluster.arn

  vpc_config {
    # both subnets - eks needs min 2 AZs for control plane
    subnet_ids = aws_subnet.public[*].id
  }

  # terraform cant detect this dependency itself, cluster creation
  # can fail if role has no permissions attached yet
  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_policy
  ]
}

# ---------- Node group ----------

# node group launches and manages the actual worker ec2s
# max 2 kept for node drain scenario later, cant drain the only node
# on demand because spot interruption in middle of chaos tests will mess up the results
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
    max_size     = 2
  }

  depends_on = [
    aws_iam_role_policy_attachment.node_worker_policy,
    aws_iam_role_policy_attachment.node_cni_policy,
    aws_iam_role_policy_attachment.node_ecr_policy
  ]
}