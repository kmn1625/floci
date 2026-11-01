# Every API the lab uses points at floci-gcp; anything missed resolves to 127.0.0.1 in the
# toolbox (egress guard) and fails instead of reaching Google. The access token comes from
# GOOGLE_OAUTH_ACCESS_TOKEN (floci-gcp does not validate external credentials), never from HCL.
locals {
  ep = var.floci_endpoint
}

provider "google" {
  project = var.project
  region  = var.region
  zone    = local.zone

  user_project_override = false
  default_labels        = local.labels

  # Run through ../scripts/tf.sh: it mints a token for the deployer service account
  # (../bootstrap), which is what IAM enforcement evaluates (FINDINGS G-09, G-10).

  big_query_custom_endpoint       = "${local.ep}/bigquery/v2/"
  cloud_billing_custom_endpoint   = "${local.ep}/v1/"
  cloudfunctions2_custom_endpoint = "${local.ep}/v2/"
  cloud_run_v2_custom_endpoint    = "${local.ep}/v2/"
  cloud_scheduler_custom_endpoint = "${local.ep}/v1/"
  cloud_tasks_custom_endpoint     = "${local.ep}/v2/"
  compute_custom_endpoint         = "${local.ep}/compute/v1/"
  # GKE shares /v1/projects/.../clusters with Managed Kafka on the one port; floci-gcp tells
  # them apart by a container.* host. A path prefix does not work: the provider strips the
  # last path segment of this endpoint (floci-gcp docs/services/gke.md).
  container_custom_endpoint        = "http://container.floci-gcp:4588/"
  eventarc_custom_endpoint         = "${local.ep}/v1/"
  firestore_custom_endpoint        = "${local.ep}/v1/"
  iam_custom_endpoint              = "${local.ep}/"
  iam_beta_custom_endpoint         = "${local.ep}/v1/"
  iam_credentials_custom_endpoint  = "${local.ep}/v1/"
  kms_custom_endpoint              = "${local.ep}/v1/"
  logging_custom_endpoint          = "${local.ep}/v2/"
  managed_kafka_custom_endpoint    = "${local.ep}/v1/"
  monitoring_custom_endpoint       = "${local.ep}/"
  pubsub_custom_endpoint           = "${local.ep}/v1/"
  resource_manager_custom_endpoint = "${local.ep}/v1/"
  secret_manager_custom_endpoint   = "${local.ep}/v1/"
  service_usage_custom_endpoint    = "${local.ep}/v1/"
  sql_custom_endpoint              = "${local.ep}/sql/v1beta4/"
  storage_custom_endpoint          = "${local.ep}/storage/v1/"
}
