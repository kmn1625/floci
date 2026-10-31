# ── Lambda behind an HTTP API ───────────────────────────────────────────────
data "archive_file" "orders_fn" {
  type        = "zip"
  output_path = "${path.module}/.build/orders_fn.zip"
  source {
    filename = "handler.py"
    content  = <<-PY
      import json, os, time, uuid
      import boto3

      table = boto3.resource("dynamodb").Table(os.environ["TABLE"])

      def handler(event, context):
          order = {"customerId": "c-" + uuid.uuid4().hex[:6], "orderId": str(int(time.time() * 1000))}
          table.put_item(Item=order)
          return {"statusCode": 201, "headers": {"Content-Type": "application/json"}, "body": json.dumps(order)}
    PY
  }
}

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${var.prefix}-orders"
  retention_in_days = 14
  kms_key_id        = aws_kms_key.lab.arn
}

resource "aws_lambda_function" "orders" {
  function_name    = "${var.prefix}-orders"
  role             = aws_iam_role.lambda.arn
  runtime          = "python3.12"
  handler          = "handler.handler"
  filename         = data.archive_file.orders_fn.output_path
  source_code_hash = data.archive_file.orders_fn.output_base64sha256
  timeout          = 10
  memory_size      = 128
  kms_key_arn      = aws_kms_key.lab.arn

  environment {
    variables = { TABLE = aws_dynamodb_table.orders.name }
  }

  tracing_config {
    mode = "Active"
  }

  depends_on = [aws_cloudwatch_log_group.lambda, aws_iam_role_policy.lambda]
}

resource "aws_apigatewayv2_api" "http" {
  name          = "${var.prefix}-http"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_integration" "orders" {
  api_id                 = aws_apigatewayv2_api.http.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.orders.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "create_order" {
  api_id    = aws_apigatewayv2_api.http.id
  route_key = "POST /orders"
  target    = "integrations/${aws_apigatewayv2_integration.orders.id}"
}

resource "aws_cloudwatch_log_group" "api" {
  name              = "/aws/apigateway/${var.prefix}-http"
  retention_in_days = 14
  kms_key_id        = aws_kms_key.lab.arn
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.http.id
  name        = "$default"
  auto_deploy = true
  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api.arn
    format          = jsonencode({ requestId = "$context.requestId", status = "$context.status", routeKey = "$context.routeKey" })
  }
}

resource "aws_lambda_permission" "api" {
  statement_id  = "AllowHttpApi"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.orders.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.http.execution_arn}/*/*"
}

# ── Alarm: jobs piling up → SNS ─────────────────────────────────────────────
resource "aws_cloudwatch_metric_alarm" "jobs_backlog" {
  alarm_name          = "${var.prefix}-jobs-backlog"
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateAgeOfOldestMessage"
  dimensions          = { QueueName = aws_sqs_queue.jobs.name }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 2
  threshold           = 900
  comparison_operator = "GreaterThanThreshold"
  alarm_actions       = [aws_sns_topic.events.arn]
}
