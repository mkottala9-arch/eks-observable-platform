resource "aws_iam_role" "dev_deploy" {
  name = "${local.project_name}-dev-deploy"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = ["sts:AssumeRoleWithWebIdentity", "sts:TagSession"]
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          # exact match, no wildcard. only main can deploy, even to dev.
          "token.actions.githubusercontent.com:sub" = "${local.github_repo}:ref:refs/heads/main"
        }
      }
    }]
  })
}

resource "aws_iam_role" "prod_deploy" {
  name = "${local.project_name}-prod-deploy"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = ["sts:AssumeRoleWithWebIdentity", "sts:TagSession"]
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          # environment-scoped, not branch-scoped. github only mints a token
          # with this claim after the environment's approval rules pass, so
          # the approval gate is enforced here in AWS, not just in github's UI.
          "token.actions.githubusercontent.com:sub" = "${local.github_repo}:environment:production"
        }
      }
    }]
  })
}


data "aws_iam_policy_document" "deploy" {
  # needed to build a kubeconfig. this is the ONLY aws call a deploy makes -
  # everything after is kubernetes, governed by the access entry instead.
  statement {
    effect    = "Allow"
    actions   = ["eks:DescribeCluster"]
    resources = [aws_eks_cluster.main.arn]
  }

  # read-only ecr, so the workflow can verify an image tag exists before
  # telling kubernetes to deploy it. the actual image pull is done by the
  # node group's role, not by these.
  statement {
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    effect = "Allow"
    actions = [
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchCheckLayerAvailability",
    ]
    resources = [aws_ecr_repository.app.arn]
  }
}

resource "aws_iam_role_policy" "dev_deploy" {
  name   = "deploy"
  role   = aws_iam_role.dev_deploy.id
  policy = data.aws_iam_policy_document.deploy.json
}

resource "aws_iam_role_policy" "prod_deploy" {
  name   = "deploy"
  role   = aws_iam_role.prod_deploy.id
  policy = data.aws_iam_policy_document.deploy.json
}

output "dev_deploy_role_arn" {
  value = aws_iam_role.dev_deploy.arn
}

output "prod_deploy_role_arn" {
  value = aws_iam_role.prod_deploy.arn
}