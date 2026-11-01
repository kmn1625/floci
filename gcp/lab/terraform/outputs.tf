output "project_number" {
  value = data.google_project.lab.number
}

output "hello_api_uri" {
  value = google_cloud_run_v2_service.hello_api.uri
}

output "gke_endpoint" {
  value = google_container_cluster.lab.endpoint
}

output "sql_instance" {
  value = google_sql_database_instance.db.connection_name
}

output "sql_public_ip" {
  value = google_sql_database_instance.db.public_ip_address
}

output "app_service_account" {
  value = google_service_account.app.email
}

output "invoker_service_account" {
  value = google_service_account.invoker.email
}

output "artifacts_bucket" {
  value = google_storage_bucket.artifacts.name
}

output "logs_bucket" {
  value = google_storage_bucket.logs.name
}

output "orders_topic" {
  value = google_pubsub_topic.orders.name
}

output "orders_subscription" {
  value = google_pubsub_subscription.orders_worker.name
}

output "orders_dlq_subscription" {
  value = google_pubsub_subscription.orders_dlq.name
}

output "kms_key" {
  value = google_kms_crypto_key.lab.id
}

output "db_password_secret" {
  value = google_secret_manager_secret.db_password.secret_id
}

output "bq_dataset" {
  value = google_bigquery_dataset.orders.dataset_id
}

output "migrate_job" {
  value = google_cloud_run_v2_job.migrate.name
}

output "probe_job" {
  value = google_cloud_scheduler_job.probe.name
}

output "gke_cluster" {
  value = google_container_cluster.lab.name
}
