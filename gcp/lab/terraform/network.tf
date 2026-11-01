# Compute Engine runs in floci-gcp's default mock mode (no instance containers): the lab
# host is saturated, and the VPC is here for GKE, Kafka and the private VM to reference.
resource "google_compute_network" "lab" {
  name                    = "${var.prefix}-vpc"
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
}

resource "google_compute_subnetwork" "private" {
  name                     = "${var.prefix}-private"
  network                  = google_compute_network.lab.id
  region                   = var.region
  ip_cidr_range            = "10.20.0.0/20"
  private_ip_google_access = true

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = "10.24.0.0/14"
  }
  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = "10.28.0.0/20"
  }
  log_config {
    aggregation_interval = "INTERVAL_5_SEC"
    flow_sampling        = 0.5
  }
}

resource "google_compute_router" "lab" {
  count   = var.include_known_emulator_gaps ? 1 : 0 # routers return 501 (G-07)
  name    = "${var.prefix}-router"
  network = google_compute_network.lab.id
  region  = var.region
}

resource "google_compute_router_nat" "lab" {
  count                              = var.include_known_emulator_gaps ? 1 : 0
  name                               = "${var.prefix}-nat"
  router                             = google_compute_router.lab[0].name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

resource "google_compute_firewall" "deny_ingress" {
  name      = "${var.prefix}-deny-all-ingress"
  network   = google_compute_network.lab.id
  direction = "INGRESS"
  priority  = 65000
  deny {
    protocol = "all"
  }
  source_ranges = ["0.0.0.0/0"]
  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }
}

resource "google_compute_firewall" "allow_iap_ssh" {
  name      = "${var.prefix}-allow-iap-ssh"
  network   = google_compute_network.lab.id
  direction = "INGRESS"
  priority  = 1000
  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
  source_ranges = ["35.235.240.0/20"] # Identity-Aware Proxy TCP forwarding
  target_tags   = ["ssh-iap"]
  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }
}

resource "google_compute_instance" "bastion" {
  count        = var.include_known_emulator_gaps ? 1 : 0 # strict projects hide debian-cloud images (G-08)
  name         = "${var.prefix}-bastion"
  machine_type = "e2-micro"
  zone         = local.zone
  tags         = ["ssh-iap"]

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
    }
    kms_key_self_link = google_kms_crypto_key.lab.id
  }
  network_interface {
    subnetwork = google_compute_subnetwork.private.id # no access_config: no public IP
  }
  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }
  metadata = {
    block-project-ssh-keys = "true"
    enable-oslogin         = "TRUE"
  }
  service_account {
    email  = google_service_account.app.email
    scopes = ["cloud-platform"]
  }
}
