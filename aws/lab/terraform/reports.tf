# Day-2 S1 (AWS): reports queue and node-exporter metrics from inside the VPC.
# T3a: forgotten with a removed block, re-adopted under a new address with an import block
# (AWS-form queue URL: the provider will not parse Floci's, FINDINGS A-22), block removed after apply.
resource "aws_sqs_queue" "report_queue" {
  name                       = "${var.prefix}-reports"
  kms_master_key_id          = aws_kms_key.lab.id
  visibility_timeout_seconds = 120
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.jobs_dlq.arn
    maxReceiveCount     = 5
  })
}


resource "aws_vpc_security_group_ingress_rule" "app_metrics" {
  security_group_id = aws_security_group.app.id
  description       = "node-exporter scrape from inside the VPC"
  cidr_ipv4         = aws_vpc.lab.cidr_block
  from_port         = 9100
  to_port           = 9100
  ip_protocol       = "tcp"
}
