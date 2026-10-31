output "account_id" {
  value = data.aws_caller_identity.current.account_id
}

output "api_endpoint" {
  value = aws_apigatewayv2_api.http.api_endpoint
}

output "bucket" {
  value = aws_s3_bucket.artifacts.bucket
}

output "orders_table" {
  value = aws_dynamodb_table.orders.name
}

output "jobs_queue_url" {
  value = aws_sqs_queue.jobs.url
}

output "events_topic_arn" {
  value = aws_sns_topic.events.arn
}

output "state_machine_arn" {
  value = aws_sfn_state_machine.order.arn
}

output "ecr_repository_url" {
  value = aws_ecr_repository.hello_api.repository_url
}

output "eks_cluster" {
  value = aws_eks_cluster.lab.name
}

output "db_endpoint" {
  value = aws_db_instance.postgres.address
}

output "db_secret_arn" {
  value = aws_secretsmanager_secret.db.arn
}

output "cache_endpoint" {
  value = aws_elasticache_replication_group.cache.primary_endpoint_address
}
