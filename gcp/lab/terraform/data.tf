# ── Cloud Storage ───────────────────────────────────────────────────────────
resource "google_storage_bucket" "artifacts" {
  name                        = "${var.prefix}-artifacts"
  location                    = upper(var.region)
  force_destroy               = true
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  versioning {
    enabled = true
  }
  encryption {
    default_kms_key_name = google_kms_crypto_key.lab.id
  }
  soft_delete_policy {
    retention_duration_seconds = 604800
  }
  lifecycle_rule {
    condition {
      num_newer_versions = 5
    }
    action {
      type = "Delete"
    }
  }
  logging {
    log_bucket = google_storage_bucket.logs.name
  }
  depends_on = [google_kms_crypto_key_iam_member.agents]

  lifecycle {
    ignore_changes = [encryption, logging] # floci-gcp does not store either block (G-14)
  }
}

# flocilab-logs, created before the deployer existed, is unreadable by anyone (G-09).
resource "google_storage_bucket" "logs" {
  name                        = "${var.prefix}-audit-logs"
  location                    = upper(var.region)
  force_destroy               = true
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  versioning {
    enabled = true
  }
  encryption {
    default_kms_key_name = google_kms_crypto_key.lab.id
  }
  depends_on = [google_kms_crypto_key_iam_member.agents]

  lifecycle {
    ignore_changes = [encryption] # floci-gcp does not store the CMEK key (G-14)
  }
}

resource "google_storage_bucket_object" "readme" {
  bucket       = google_storage_bucket.artifacts.name
  name         = "README.txt"
  content      = "floci-gcp lab artifacts bucket\n"
  content_type = "text/plain"
}

resource "google_storage_bucket_iam_member" "app_reader" {
  bucket = google_storage_bucket.artifacts.name
  role   = "roles/storage.objectViewer"
  member = google_service_account.app.member
}

# ── BigQuery ────────────────────────────────────────────────────────────────
resource "google_bigquery_dataset" "orders" {
  dataset_id                 = replace("${var.prefix}_orders", "-", "_")
  location                   = "US"
  delete_contents_on_destroy = true
  default_encryption_configuration {
    kms_key_name = google_kms_crypto_key.lab.id
  }
  access {
    role          = "OWNER"
    special_group = "projectOwners"
  }
  access {
    role          = "READER"
    user_by_email = google_service_account.app.email
  }
  depends_on = [google_kms_crypto_key_iam_member.agents]
}

resource "google_bigquery_table" "orders" {
  dataset_id          = google_bigquery_dataset.orders.dataset_id
  table_id            = "orders"
  deletion_protection = false
  time_partitioning {
    type  = "DAY"
    field = "created_at"
  }
  schema = jsonencode([
    { name = "order_id", type = "STRING", mode = "REQUIRED" },
    { name = "amount", type = "NUMERIC", mode = "REQUIRED" },
    { name = "created_at", type = "TIMESTAMP", mode = "REQUIRED" },
  ])
}

# ── Cloud SQL for PostgreSQL 16 (floci-gcp runs a real postgres container) ──
resource "google_sql_database_instance" "db" {
  name                = "${var.prefix}-pg"
  database_version    = "POSTGRES_16"
  deletion_protection = false
  encryption_key_name = google_kms_crypto_key.lab.id

  settings {
    tier              = "db-custom-1-3840"
    edition           = "ENTERPRISE"
    availability_type = "ZONAL"
    disk_autoresize   = true
    user_labels       = local.labels

    ip_configuration {
      ipv4_enabled = true
      ssl_mode     = "ENCRYPTED_ONLY"
    }
    backup_configuration {
      enabled                        = true
      point_in_time_recovery_enabled = true
    }
    database_flags {
      name  = "log_connections"
      value = "on"
    }
    location_preference {
      zone = local.zone
    }
  }
  depends_on = [google_kms_crypto_key_iam_member.agents]
}

resource "google_sql_database" "app" {
  name     = "app"
  instance = google_sql_database_instance.db.name
}

resource "google_sql_user" "app" {
  name     = "app"
  instance = google_sql_database_instance.db.name
  password = random_password.db.result
}

# ── Firestore (data plane is gRPC only; the database is created over REST) ──
resource "google_firestore_database" "default" {
  count                   = var.include_known_emulator_gaps ? 1 : 0 # no Firestore Admin REST API (G-06)
  name                    = "(default)"
  location_id             = "nam5"
  type                    = "FIRESTORE_NATIVE"
  deletion_policy         = "DELETE"
  delete_protection_state = "DELETE_PROTECTION_DISABLED"
}
