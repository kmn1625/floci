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
