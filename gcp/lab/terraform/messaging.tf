# ── Pub/Sub: orders topic, dead-letter topic, pull subscription ─────────────
resource "google_pubsub_topic" "orders" {
  name                       = "${var.prefix}-orders"
  kms_key_name               = google_kms_crypto_key.lab.id
  message_retention_duration = "86400s"
  depends_on                 = [google_kms_crypto_key_iam_member.agents]
  lifecycle {
    ignore_changes = [kms_key_name] # floci-gcp does not store the topic CMEK key (G-12)
  }
}

resource "google_pubsub_topic" "dead_letter" {
  name         = "${var.prefix}-orders-dlq"
  kms_key_name = google_kms_crypto_key.lab.id
  depends_on   = [google_kms_crypto_key_iam_member.agents]
  lifecycle {
    ignore_changes = [kms_key_name] # floci-gcp does not store the topic CMEK key (G-12)
  }
}

resource "google_pubsub_subscription" "orders_worker" {
  name                       = "${var.prefix}-orders-worker"
  topic                      = google_pubsub_topic.orders.id
  ack_deadline_seconds       = 30
  message_retention_duration = "604800s"
  enable_message_ordering    = true

  retry_policy {
    minimum_backoff = "10s"
    maximum_backoff = "300s"
  }
  dead_letter_policy {
    dead_letter_topic     = google_pubsub_topic.dead_letter.id
    max_delivery_attempts = 5
  }
}

resource "google_pubsub_subscription" "orders_dlq" {
  name  = "${var.prefix}-orders-dlq"
  topic = google_pubsub_topic.dead_letter.id
}

resource "google_pubsub_topic_iam_member" "app_publisher" {
  topic  = google_pubsub_topic.orders.id
  role   = "roles/pubsub.publisher"
  member = google_service_account.app.member
}

# On GCP the Pub/Sub service agent forwards undeliverable messages to the DLQ topic.
resource "google_pubsub_topic_iam_member" "dlq_publisher" {
  topic  = google_pubsub_topic.dead_letter.id
  role   = "roles/pubsub.publisher"
  member = local.service_agents.pubsub
}

# ── Eventarc: orders messages → hello-api on Cloud Run ──────────────────────
resource "google_eventarc_trigger" "orders" {
  name            = "${var.prefix}-orders"
  location        = var.region
  service_account = google_service_account.invoker.email

  matching_criteria {
    attribute = "type"
    value     = "google.cloud.pubsub.topic.v1.messagePublished"
  }
  transport {
    pubsub {
      topic = google_pubsub_topic.orders.id
    }
  }
  destination {
    cloud_run_service {
      service = google_cloud_run_v2_service.hello_api.name
      region  = var.region
      path    = "/"
    }
  }
}

# ── Cloud Scheduler: health probe of hello-api every 5 minutes ──────────────
resource "google_cloud_scheduler_job" "probe" {
  name             = "${var.prefix}-probe"
  region           = var.region
  schedule         = "*/5 * * * *"
  time_zone        = "Etc/UTC"
  attempt_deadline = "30s"

  retry_config {
    retry_count = 1
  }
  http_target {
    http_method = "GET"
    uri         = "${google_cloud_run_v2_service.hello_api.uri}/healthz"
    oidc_token {
      service_account_email = google_service_account.invoker.email
      audience              = google_cloud_run_v2_service.hello_api.uri
    }
  }
  lifecycle {
    ignore_changes = [http_target[0].oidc_token] # floci-gcp does not store the OIDC token (G-13)
  }
}

# ── Cloud Tasks ─────────────────────────────────────────────────────────────
resource "google_cloud_tasks_queue" "orders" {
  count    = var.include_known_emulator_gaps ? 1 : 0 # Cloud Tasks is gRPC only (G-05)
  name     = "${var.prefix}-orders"
  location = var.region
  rate_limits {
    max_dispatches_per_second = 5
  }
  retry_config {
    max_attempts = 5
  }
}

# ── Managed Kafka (control plane only here: FLOCI_GCP_SERVICES_KAFKA_MOCK) ──
resource "google_managed_kafka_cluster" "events" {
  count      = var.include_known_emulator_gaps ? 1 : 0 # CreateCluster fails on int64-as-string (G-02)
  cluster_id = "${var.prefix}-events"
  location   = var.region
  capacity_config {
    vcpu_count   = 3
    memory_bytes = 3221225472
  }
  gcp_config {
    access_config {
      network_configs {
        subnet = google_compute_subnetwork.private.id
      }
    }
    kms_key = google_kms_crypto_key.lab.id
  }
}

resource "google_managed_kafka_topic" "orders" {
  count              = var.include_known_emulator_gaps ? 1 : 0
  topic_id           = "orders"
  cluster            = google_managed_kafka_cluster.events[0].cluster_id
  location           = var.region
  partition_count    = 3
  replication_factor = 3
}

# ── Logging and Monitoring ──────────────────────────────────────────────────
resource "google_logging_project_sink" "audit" {
  name                   = "${var.prefix}-audit-to-gcs"
  destination            = "storage.googleapis.com/${google_storage_bucket.logs.name}"
  filter                 = "logName:\"cloudaudit.googleapis.com\" OR severity>=ERROR"
  unique_writer_identity = true
}

resource "google_storage_bucket_iam_member" "sink_writer" {
  bucket = google_storage_bucket.logs.name
  role   = "roles/storage.objectCreator"
  member = google_logging_project_sink.audit.writer_identity
}

resource "google_monitoring_metric_descriptor" "orders" {
  type         = "custom.googleapis.com/hello_api/orders_total"
  display_name = "hello-api orders"
  description  = "Orders accepted by hello-api"
  metric_kind  = "GAUGE"
  value_type   = "INT64"
  unit         = "1"
  labels {
    key         = "env"
    value_type  = "STRING"
    description = "Deployment environment"
  }
}

# Day-2 T4 (GCP): address renamed orders_dlq -> dead_letter; moved keeps the topic and its messages.
moved {
  from = google_pubsub_topic.orders_dlq
  to   = google_pubsub_topic.dead_letter
}
