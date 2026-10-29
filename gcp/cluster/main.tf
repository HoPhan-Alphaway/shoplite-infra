# Ephemeral layer: created for a study session, destroyed afterwards (gke-up / gke-down).
# Nothing here holds data you need to keep: data lives in the persistent layer, in the
# external Postgres, and in git.

# --- Network ----------------------------------------------------------------------------
# Nodes keep public IPs (no Cloud NAT to pay for). Each node IP counts against the trial's
# 4 in-use address quota, which is why the pool has 2 nodes: 2 nodes + 1 load balancer = 3.

resource "google_compute_network" "shoplite" {
  name                    = var.cluster_name
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "nodes" {
  name          = "${var.cluster_name}-nodes"
  region        = var.region
  network       = google_compute_network.shoplite.id
  ip_cidr_range = var.subnet_cidr

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = var.pods_cidr
  }

  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = var.services_cidr
  }
}

# --- Node identity ----------------------------------------------------------------------

resource "google_service_account" "nodes" {
  account_id   = "${var.cluster_name}-nodes"
  display_name = "ShopLite GKE nodes (minimal)"
}

resource "google_project_iam_member" "nodes_default_role" {
  project = var.project_id
  role    = "roles/container.defaultNodeServiceAccount"
  member  = "serviceAccount:${google_service_account.nodes.email}"
}

# --- Cluster ----------------------------------------------------------------------------

resource "google_container_cluster" "shoplite" {
  name     = var.cluster_name
  location = var.zone # a zone, not a region => zonal cluster

  network    = google_compute_network.shoplite.id
  subnetwork = google_compute_subnetwork.nodes.id

  # We manage the pool separately; this tiny default pool is deleted right after creation.
  remove_default_node_pool = true
  initial_node_count       = 1
  node_config {
    machine_type = "e2-medium"
    disk_size_gb = 20
  }

  # Ephemeral by design: `terraform destroy` must be able to delete it.
  deletion_protection = false

  networking_mode = "VPC_NATIVE"
  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  release_channel {
    channel = "REGULAR"
  }

  # We run our own Loki/Prometheus; skip Google's logging/monitoring agents (fewer system
  # pods, no Cloud Logging charges). To be confirmed at the first `terraform plan`.
  logging_service    = "none"
  monitoring_service = "none"
  monitoring_config {
    managed_prometheus {
      enabled = false
    }
  }

  addons_config {
    # Kong is the ingress (a plain network load balancer); the GKE L7 controller is not needed.
    http_load_balancing {
      disabled = true
    }
    horizontal_pod_autoscaling {
      disabled = false
    }
    gce_persistent_disk_csi_driver_config {
      enabled = true
    }
  }

  resource_labels = {
    app = "shoplite"
  }
}

resource "google_container_node_pool" "main" {
  name       = "main"
  cluster    = google_container_cluster.shoplite.name
  location   = var.zone
  node_count = var.node_count # no autoscaler: there is no quota headroom to scale into

  node_config {
    machine_type    = var.machine_type
    disk_size_gb    = var.disk_size_gb
    disk_type       = "pd-balanced"
    service_account = google_service_account.nodes.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }

    labels = {
      pool = "main"
    }
  }

  management {
    auto_repair  = true
    auto_upgrade = true # forced on by the release channel anyway
  }

  # An upgrade adds one temporary node: 3 nodes = 12 vCPU, exactly the trial cap, and 4 IPs
  # with the load balancer. Fits, but only just. Do not raise node_count without checking quota.
  upgrade_settings {
    strategy        = "SURGE"
    max_surge       = 1
    max_unavailable = 0
  }

  depends_on = [google_project_iam_member.nodes_default_role]
}

# --- Workload Identity bindings ---------------------------------------------------------
# Allow a Kubernetes ServiceAccount to act as a Google service account. These live here (not in
# gcp/persistent) because the binding is only accepted once the cluster's workload pool exists.

data "google_service_account" "wi" {
  for_each   = var.workload_identity
  account_id = each.value.gsa
}

resource "google_service_account_iam_member" "wi" {
  for_each           = var.workload_identity
  service_account_id = data.google_service_account.wi[each.key].name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[${each.value.namespace}/${each.value.ksa}]"

  depends_on = [google_container_cluster.shoplite]
}
