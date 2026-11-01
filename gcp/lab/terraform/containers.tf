# ── GKE (floci-gcp runs a real k3s container per cluster) ───────────────────
resource "google_container_cluster" "lab" {
  name                     = "${var.prefix}-gke"
  location                 = var.region
  deletion_protection      = false
  remove_default_node_pool = true
  initial_node_count       = 1
  network                  = google_compute_network.lab.id
  subnetwork               = google_compute_subnetwork.private.id
  resource_labels          = local.labels

  release_channel {
    channel = "REGULAR"
  }
  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }
  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = true
    master_ipv4_cidr_block  = "172.16.0.32/28"
  }
  master_authorized_networks_config {
    cidr_blocks {
      cidr_block   = google_compute_subnetwork.private.ip_cidr_range
      display_name = "private subnet"
    }
  }
  workload_identity_config {
    workload_pool = "${var.project}.svc.id.goog"
  }
  database_encryption {
    state    = "ENCRYPTED"
    key_name = google_kms_crypto_key.lab.id
  }
  network_policy {
    enabled  = true
    provider = "CALICO"
  }
  addons_config {
    network_policy_config {
      disabled = false
    }
  }
  master_auth {
    client_certificate_config {
      issue_client_certificate = false
    }
  }
  enable_legacy_abac = false
  depends_on         = [google_kms_crypto_key_iam_member.agents]
}

resource "google_container_node_pool" "default" {
  name       = "default"
  cluster    = google_container_cluster.lab.id
  location   = var.region
  node_count = 1

  node_config {
    machine_type    = "e2-standard-2"
    service_account = google_service_account.gke_nodes.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]
    labels          = { pool = "default" }
    workload_metadata_config {
      mode = "GKE_METADATA"
    }
    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }
  }
  management {
    auto_repair  = true
    auto_upgrade = true
  }
  lifecycle {
    # The provider reads node_count from Compute instance groups, which floci-gcp does not
    # model, so it always reads 0 (floci-gcp docs/services/gke.md).
    ignore_changes = [node_count]
  }
}

# Workload identity: the hello-api KSA acts as the app service account.
resource "google_service_account_iam_member" "app_workload_identity" {
  service_account_id = google_service_account.app.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project}.svc.id.goog[hello/hello-api]"
}

# ── Cloud Run: hello-api service and a one-shot job ─────────────────────────
resource "google_cloud_run_v2_service" "hello_api" {
  name                = "hello-api"
  location            = var.region
  deletion_protection = false
  ingress             = "INGRESS_TRAFFIC_INTERNAL_ONLY"

  template {
    service_account = google_service_account.app.email
    scaling {
      min_instance_count = 0
      max_instance_count = 2
    }
    containers {
      image = var.hello_api_image
      ports {
        container_port = 8080
      }
      env {
        name  = "APP_ENV"
        value = "cloudrun"
      }
      resources {
        limits = { cpu = "1", memory = "256Mi" }
      }
      startup_probe {
        http_get {
          path = "/readyz"
        }
      }
      liveness_probe {
        http_get {
          path = "/healthz"
        }
      }
    }
  }
}

resource "google_cloud_run_v2_service_iam_member" "invoker" {
  name     = google_cloud_run_v2_service.hello_api.name
  location = var.region
  role     = "roles/run.invoker"
  member   = google_service_account.invoker.member
}

resource "google_cloud_run_v2_job" "migrate" {
  name                = "${var.prefix}-migrate"
  location            = var.region
  deletion_protection = false

  template {
    task_count = 1
    template {
      service_account = google_service_account.app.email
      max_retries     = 1
      timeout         = "60s"
      containers {
        image   = "busybox:1.37.0"
        command = ["sh", "-c", "echo migrate: nothing to do"]
      }
    }
  }
}

# ── Cloud Functions gen2 (control plane only in floci-gcp) ──────────────────
data "archive_file" "fn" {
  type        = "zip"
  output_path = "${path.module}/.build/fn.zip"
  source {
    filename = "main.py"
    content  = "def handler(request):\n    return 'ok'\n"
  }
  source {
    filename = "requirements.txt"
    content  = "functions-framework==3.10.0\n"
  }
}

resource "google_storage_bucket_object" "fn_source" {
  bucket = google_storage_bucket.artifacts.name
  name   = "functions/fn-${data.archive_file.fn.output_md5}.zip"
  source = data.archive_file.fn.output_path
}

resource "google_cloudfunctions2_function" "orders_hook" {
  name     = "${var.prefix}-orders-hook"
  location = var.region

  build_config {
    runtime     = "python312"
    entry_point = "handler"
    source {
      storage_source {
        bucket = google_storage_bucket.artifacts.name
        object = google_storage_bucket_object.fn_source.name
      }
    }
  }
  service_config {
    max_instance_count    = 1
    available_memory      = "256M"
    timeout_seconds       = 30
    ingress_settings      = "ALLOW_INTERNAL_ONLY"
    service_account_email = google_service_account.app.email
  }
}
