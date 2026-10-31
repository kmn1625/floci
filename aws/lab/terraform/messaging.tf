# ── SQS with a dead-letter queue, KMS-encrypted ─────────────────────────────
resource "aws_sqs_queue" "jobs_dlq" {
  name                      = "${var.prefix}-jobs-dlq"
  kms_master_key_id         = aws_kms_key.lab.id
  message_retention_seconds = 1209600
}

resource "aws_sqs_queue" "jobs" {
  name                       = "${var.prefix}-jobs"
  kms_master_key_id          = aws_kms_key.lab.id
  visibility_timeout_seconds = 60
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.jobs_dlq.arn
    maxReceiveCount     = 5
  })
}

# SNS, EventBridge and Scheduler may deliver to the queue; nothing else.
data "aws_iam_policy_document" "jobs_queue" {
  statement {
    sid       = "SnsEventsDeliver"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.jobs.arn]
    principals {
      type        = "Service"
      identifiers = ["sns.amazonaws.com", "events.amazonaws.com"]
    }
    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_sns_topic.events.arn, aws_cloudwatch_event_rule.heartbeat.arn]
    }
  }
}

resource "aws_sqs_queue_policy" "jobs" {
  queue_url = aws_sqs_queue.jobs.id
  policy    = data.aws_iam_policy_document.jobs_queue.json
}

# ── SNS fan-out into the queue ──────────────────────────────────────────────
resource "aws_sns_topic" "events" {
  name              = "${var.prefix}-events"
  kms_master_key_id = aws_kms_key.lab.id
}

resource "aws_sns_topic_subscription" "events_to_jobs" {
  topic_arn            = aws_sns_topic.events.arn
  protocol             = "sqs"
  endpoint             = aws_sqs_queue.jobs.arn
  raw_message_delivery = true
}

# ── EventBridge: a heartbeat every 5 minutes into the queue ─────────────────
resource "aws_cloudwatch_event_rule" "heartbeat" {
  name                = "${var.prefix}-heartbeat"
  schedule_expression = "rate(5 minutes)"
}

resource "aws_cloudwatch_event_target" "heartbeat_to_jobs" {
  rule = aws_cloudwatch_event_rule.heartbeat.name
  arn  = aws_sqs_queue.jobs.arn
}

# ── EventBridge Scheduler (separate service) with its own role ──────────────
data "aws_iam_policy_document" "scheduler_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "scheduler" {
  name               = "${var.prefix}-scheduler"
  assume_role_policy = data.aws_iam_policy_document.scheduler_assume.json
}

resource "aws_iam_role_policy" "scheduler" {
  name = "send-to-jobs"
  role = aws_iam_role.scheduler.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = "sqs:SendMessage", Resource = aws_sqs_queue.jobs.arn },
      { Effect = "Allow", Action = ["kms:GenerateDataKey", "kms:Decrypt"], Resource = aws_kms_key.lab.arn },
    ]
  })
}

resource "aws_scheduler_schedule" "nightly" {
  name                = "${var.prefix}-nightly"
  schedule_expression = "cron(0 2 * * ? *)"
  flexible_time_window {
    mode = "OFF"
  }
  target {
    arn      = aws_sqs_queue.jobs.arn
    role_arn = aws_iam_role.scheduler.arn
    input    = jsonencode({ job = "nightly-report" })
  }
}

# ── Kinesis ─────────────────────────────────────────────────────────────────
resource "aws_kinesis_stream" "clicks" {
  name             = "${var.prefix}-clicks"
  retention_period = 24
  encryption_type  = "KMS"
  kms_key_id       = aws_kms_key.lab.id
  stream_mode_details {
    stream_mode = "ON_DEMAND"
  }
}

# ── Step Functions: validate an order, then store it ────────────────────────
data "aws_iam_policy_document" "sfn_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["states.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "sfn" {
  name               = "${var.prefix}-sfn"
  assume_role_policy = data.aws_iam_policy_document.sfn_assume.json
}

resource "aws_iam_role_policy" "sfn" {
  name = "store-order"
  role = aws_iam_role.sfn.id
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "dynamodb:PutItem", Resource = aws_dynamodb_table.orders.arn }]
  })
}

resource "aws_sfn_state_machine" "order" {
  name     = "${var.prefix}-order"
  role_arn = aws_iam_role.sfn.arn
  definition = jsonencode({
    Comment = "Validate and store an order"
    StartAt = "Validate"
    States = {
      Validate = {
        Type    = "Choice"
        Choices = [{ Variable = "$.customerId", IsPresent = true, Next = "Store" }]
        Default = "Reject"
      }
      Store = {
        Type     = "Task"
        Resource = "arn:aws:states:::dynamodb:putItem"
        Parameters = {
          TableName = aws_dynamodb_table.orders.name
          Item = {
            "customerId" = { "S.$" = "$.customerId" }
            "orderId"    = { "S.$" = "$$.Execution.Name" }
          }
        }
        End = true
      }
      Reject = { Type = "Fail", Error = "MissingCustomer" }
    }
  })
}
