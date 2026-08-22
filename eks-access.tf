# ---------- dev ----------

# maps the IAM role ARN to a kubernetes identity. on its own this grants
# nothing - it just makes the cluster recognise the role.
resource "aws_eks_access_entry" "dev_deploy" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = aws_iam_role.dev_deploy.arn
  type          = "STANDARD"
}

# attaches actual permissions, scoped to one namespace. this is what stops
# dev-deploy from touching app-prod - IAM can't, because helm talks to the
# kubernetes api, not to aws.
resource "aws_eks_access_policy_association" "dev_deploy" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = aws_iam_role.dev_deploy.arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy"

  access_scope {
    type       = "namespace"
    namespaces = ["app-dev"]
  }

  depends_on = [aws_eks_access_entry.dev_deploy]
}

# ---------- prod ----------

resource "aws_eks_access_entry" "prod_deploy" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = aws_iam_role.prod_deploy.arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "prod_deploy" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = aws_iam_role.prod_deploy.arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy"

  access_scope {
    type       = "namespace"
    namespaces = ["app-prod"]
  }

  depends_on = [aws_eks_access_entry.prod_deploy]
}