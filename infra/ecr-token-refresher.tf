# Durable registry auth for the Harness generic-mitigation demo. Harness's Run step
# needs its own working registry credentials (confirmed - see README: a credential-free
# DockerRegistry connector fails because Harness's lite-engine resolves the container
# entrypoint via a direct registry API call using the connector's own credentials,
# separate from kubelet's node-IAM-backed pull). ECR login passwords expire in ~12h, so
# this keeps a Secrets Manager secret fresh automatically rather than relying on a
# manually-refreshed static token.

data "aws_caller_identity" "current" {}

resource "aws_secretsmanager_secret" "ecr_docker_password" {
  name        = "harness-poc/ecr-docker-password"
  description = "Auto-refreshed ECR docker login password for the Harness generic-mitigation demo"
}

data "archive_file" "ecr_token_refresher" {
  type        = "zip"
  source_file = "${path.module}/lambda-src/ecr_token_refresher.py"
  output_path = "${path.module}/lambda-src/ecr_token_refresher.zip"
}

resource "aws_iam_role" "ecr_token_refresher" {
  name = "harness-poc-ecr-token-refresher"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "ecr_token_refresher" {
  name = "ecr-token-refresher-policy"
  role = aws_iam_role.ecr_token_refresher.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
      {
        # ECR authorization tokens are principal-scoped: whoever calls
        # GetAuthorizationToken is who the resulting password authenticates as
        # on the actual pull. Since this Lambda mints the token, its own role
        # needs real read access to the repo, not just token-minting rights.
        Effect = "Allow"
        Action = [
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchCheckLayerAvailability",
        ]
        Resource = "arn:aws:ecr:us-east-1:547641909728:repository/harness-poc/connectivity-check"
      },
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:PutSecretValue", "secretsmanager:DescribeSecret"]
        Resource = aws_secretsmanager_secret.ecr_docker_password.arn
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

resource "aws_lambda_function" "ecr_token_refresher" {
  function_name    = "harness-poc-ecr-token-refresher"
  role             = aws_iam_role.ecr_token_refresher.arn
  handler          = "ecr_token_refresher.handler"
  runtime          = "python3.12"
  timeout          = 30
  filename         = data.archive_file.ecr_token_refresher.output_path
  source_code_hash = data.archive_file.ecr_token_refresher.output_base64sha256

  environment {
    variables = {
      ECR_REGISTRY_ID = data.aws_caller_identity.current.account_id
      SECRET_ID       = aws_secretsmanager_secret.ecr_docker_password.id
    }
  }
}

resource "aws_cloudwatch_event_rule" "ecr_token_refresh_schedule" {
  name                = "harness-poc-ecr-token-refresh"
  description         = "Refresh the ECR docker login password well within its ~12h expiry"
  schedule_expression = "rate(6 hours)"
}

resource "aws_cloudwatch_event_target" "ecr_token_refresh_target" {
  rule = aws_cloudwatch_event_rule.ecr_token_refresh_schedule.name
  arn  = aws_lambda_function.ecr_token_refresher.arn
}

resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ecr_token_refresher.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.ecr_token_refresh_schedule.arn
}

output "ecr_docker_password_secret_arn" {
  value = aws_secretsmanager_secret.ecr_docker_password.arn
}

output "ecr_token_refresher_function_name" {
  value = aws_lambda_function.ecr_token_refresher.function_name
}
