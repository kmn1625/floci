# ── APIs ─────────────────────────────────────────────────────────────────────
resource "google_project_service" "apis" {
  for_each = toset([
    "bigquery.googleapis.com", "cloudfunctions.googleapis.com", "cloudkms.googleapis.com",
    "cloudscheduler.googleapis.com", "cloudtasks.googleapis.com", "compute.googleapis.com",
    "container.googleapis.com", "eventarc.googleapis.com", "iam.googleapis.com",
    "logging.googleapis.com", "managedkafka.googleapis.com", "monitoring.googleapis.com",
    "pubsub.googleapis.com", "run.googleapis.com", "secretmanager.googleapis.com",
    "sqladmin.googleapis.com", "storage.googleapis.com",
  ])
  service            = each.value
  disable_on_destroy = false
}

# ── Service accounts: one per workload, no keys ─────────────────────────────
resource "google_service_account" "app" {
  account_id   = "${var.prefix}-app"
  display_name = "hello-api runtime (Cloud Run, GKE workload identity)"
}

resource "google_service_account" "gke_nodes" {
  account_id   = "${var.prefix}-gke-nodes"
  display_name = "GKE node pool"
}

resource "google_service_account" "invoker" {
  account_id   = "${var.prefix}-invoker"
  display_name = "Scheduler and Eventarc caller of hello-api"
}

resource "google_project_iam_member" "app" {
  for_each = toset(["roles/logging.logWriter", "roles/monitoring.metricWriter", "roles/cloudtrace.agent"])
  project  = var.project
  role     = each.value
  member   = google_service_account.app.member
}

resource "google_project_iam_member" "gke_nodes" {
  for_each = toset(["roles/logging.logWriter", "roles/monitoring.metricWriter", "roles/container.defaultNodeServiceAccount"])
  project  = var.project
  role     = each.value
  member   = google_service_account.gke_nodes.member
}

resource "google_project_iam_member" "invoker_eventarc" {
  project = var.project
  role    = "roles/eventarc.eventReceiver"
  member  = google_service_account.invoker.member
}

resource "google_project_iam_custom_role" "auditor" {
  role_id     = "${replace(var.prefix, "-", "_")}_auditor"
  title       = "Lab auditor"
  description = "Read-only view of the lab's storage and secrets metadata"
  permissions = ["storage.buckets.get", "storage.buckets.list", "secretmanager.secrets.list"]
}

# ── KMS: one key for every CMEK-capable service ─────────────────────────────
resource "google_kms_key_ring" "lab" {
  name     = "${var.prefix}-ring"
  location = var.region
}

resource "google_kms_crypto_key" "lab" {
  name            = "${var.prefix}-key"
  key_ring        = google_kms_key_ring.lab.id
  purpose         = "ENCRYPT_DECRYPT"
  rotation_period = "7776000s" # 90 days

  lifecycle {
    prevent_destroy = false
  }
}

# Google-managed service agents that encrypt with the key on GCP.
locals {
  service_agents = {
    storage  = "serviceAccount:service-${data.google_project.lab.number}@gs-project-accounts.iam.gserviceaccount.com"
    pubsub   = "serviceAccount:service-${data.google_project.lab.number}@gcp-sa-pubsub.iam.gserviceaccount.com"
    bigquery = "serviceAccount:bq-${data.google_project.lab.number}@bigquery-encryption.iam.gserviceaccount.com"
    secrets  = "serviceAccount:service-${data.google_project.lab.number}@gcp-sa-secretmanager.iam.gserviceaccount.com"
    gke      = "serviceAccount:service-${data.google_project.lab.number}@container-engine-robot.iam.gserviceaccount.com"
    sql      = "serviceAccount:service-${data.google_project.lab.number}@gcp-sa-cloud-sql.iam.gserviceaccount.com"
  }
}

resource "google_kms_crypto_key_iam_member" "agents" {
  # KMS key IAM policy methods are not served over REST (FINDINGS G-04)
  for_each      = var.include_known_emulator_gaps ? local.service_agents : {}
  crypto_key_id = google_kms_crypto_key.lab.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = each.value
}

# ── Secret Manager: the database password, readable only by the app ────────
resource "random_password" "db" {
  length  = 24
  special = false
}

resource "google_secret_manager_secret" "db_password" {
  secret_id = "${var.prefix}-db-password"
  replication {
    user_managed {
      replicas {
        location = var.region
        customer_managed_encryption {
          kms_key_name = google_kms_crypto_key.lab.id
        }
      }
    }
  }
  depends_on = [google_kms_crypto_key_iam_member.agents]

  lifecycle {
    # floci-gcp drops user-managed replicas, their CMEK key and all labels (G-11)
    # terraform_labels draws a "redundant" warning, but without it the default_labels diff returns.
    ignore_changes = [replication, labels, terraform_labels, effective_labels]
  }
}

resource "google_secret_manager_secret_version" "db_password" {
  secret      = google_secret_manager_secret.db_password.id
  secret_data = random_password.db.result
}

resource "google_secret_manager_secret_iam_member" "app" {
  secret_id = google_secret_manager_secret.db_password.id
  role      = "roles/secretmanager.secretAccessor"
  member    = google_service_account.app.member
}
