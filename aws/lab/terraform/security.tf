# ── KMS: one customer-managed key for the lab's data at rest ────────────────
resource "aws_kms_key" "lab" {
  description             = "${var.prefix} data at rest"
  deletion_window_in_days = 7
  enable_key_rotation     = true
}

resource "aws_kms_alias" "lab" {
  name          = "alias/${var.prefix}"
  target_key_id = aws_kms_key.lab.key_id
}

# ── IAM: Lambda execution role (least privilege) ────────────────────────────
data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda" {
  name               = "${var.prefix}-lambda"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

data "aws_iam_policy_document" "lambda" {
  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.lambda.arn}:*"]
  }
  statement {
    sid       = "Orders"
    actions   = ["dynamodb:PutItem", "dynamodb:GetItem"]
    resources = [aws_dynamodb_table.orders.arn]
  }
  statement {
    sid       = "Queue"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.jobs.arn]
  }
  statement {
    sid       = "Decrypt"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
    resources = [aws_kms_key.lab.arn]
  }
}

resource "aws_iam_role_policy" "lambda" {
  name   = "least-privilege"
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.lambda.json
}

# ── Secrets and parameters ──────────────────────────────────────────────────
resource "random_password" "db" {
  length  = 24
  special = false # RDS master passwords reject some symbols
}

resource "aws_secretsmanager_secret" "db" {
  name                    = "${var.prefix}/db-master"
  kms_key_id              = aws_kms_key.lab.arn
  recovery_window_in_days = 0 # lab: allow immediate re-create
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id     = aws_secretsmanager_secret.db.id
  secret_string = jsonencode({ username = "labadmin", password = random_password.db.result })
}

resource "aws_ssm_parameter" "app_env" {
  name  = "/${var.prefix}/app/env"
  type  = "String"
  value = var.environment
}

resource "aws_ssm_parameter" "feature_flag" {
  name   = "/${var.prefix}/app/feature-x"
  type   = "SecureString"
  key_id = aws_kms_key.lab.arn
  value  = "enabled"
}

# ── Identity: Cognito user pool for app sign-in ─────────────────────────────
resource "aws_cognito_user_pool" "app" {
  name                     = "${var.prefix}-users"
  auto_verified_attributes = ["email"]
  mfa_configuration        = "OPTIONAL"

  software_token_mfa_configuration {
    enabled = true
  }

  password_policy {
    minimum_length    = 12
    require_lowercase = true
    require_uppercase = true
    require_numbers   = true
    require_symbols   = true
  }
}

resource "aws_cognito_user_pool_client" "app" {
  name            = "${var.prefix}-web"
  user_pool_id    = aws_cognito_user_pool.app.id
  generate_secret = false
}
