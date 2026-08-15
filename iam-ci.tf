resource "aws_iam_role" "ci" {
  name = "${local.project_name}-ci"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = ["sts:AssumeRoleWithWebIdentity", "sts:TagSession"]
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          "token.actions.githubusercontent.com:sub" = "${local.github_repo}:*"
        }
      }
    }]
  })
}

# what this role can do: push to one ecr repo. no delete actions.
resource "aws_iam_role_policy" "ci_ecr" {
  name = "ecr-push"
  role = aws_iam_role.ci.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # this action can't be scoped to a repo, it's account-wide by design
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage",
        ]
        Resource = aws_ecr_repository.app.arn
      }
    ]
  })
}

output "ci_role_arn" {
  value = aws_iam_role.ci.arn
}