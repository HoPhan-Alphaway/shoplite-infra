# Persistent layer: things that are kept when the cluster is deleted.
# Cost when idle is close to zero (empty buckets, secrets, service accounts).
#
#   - GCS buckets for Loki (logs) and Tempo (traces)
#   - Secret Manager: empty "shells". Values are NEVER in Terraform (they would land in
#     state as clear text); scripts/seed-secrets.sh fills them once.
#   - Google service accounts (GSAs) used through Workload Identity by Loki, Tempo and
#     External Secrets. The bindings from Kubernetes ServiceAccounts to these GSAs live in
#     gcp/cluster (they need the cluster's workload pool to exist first).

locals {
  # Single source of truth, shared with scripts/neon-provision.sh: one service name per line, "#" for comments.
  workloads = [for l in split("\n", file("${path.module}/../../services.txt")) : trimspace(l) if trimspace(l) != "" && !startswith(trimspace(l), "#")]
  envs      = ["dev", "prod"]

  # One secret per external Postgres database. Value (JSON): host, port, dbname, username, password.
  db_secrets = concat(
    ["shoplite-db-keycloak"],
    [for pair in setproduct(local.workloads, local.envs) : "shoplite-db-${pair[0]}-${pair[1]}"],
  )

  # Mirrors what bootstrap/secrets.sh creates for the k3d cluster.
  platform_secrets = [
    "shoplite-realm-rsa-private-key",
    "shoplite-realm-rsa-public-key", # Kong's jwt credential; derived from the private key by seed-secrets.sh
    "shoplite-order-service-client-secret",
    "shoplite-grafana-client-secret",
    "shoplite-argocd-client-secret",
    "shoplite-kafka-ui-client-secret",
    "shoplite-alice-password",
    "shoplite-bob-password",
    "shoplite-devops1-password",
    "shoplite-viewer1-password",
    "shoplite-grafana-admin-password",
    "shoplite-cloudflare-api-token", # external-dns
    "shoplite-tls-origin",           # Cloudflare Origin CA certificate (JSON tls.crt / tls.key): issued once, valid for years, so a rebuild needs no new certificate
  ]

  secret_names = toset(concat(local.db_secrets, local.platform_secrets, var.extra_secret_names))
}

# --- Object storage -------------------------------------------------------------------

resource "google_storage_bucket" "loki" {
  name                        = "${var.project_id}-loki"
  location                    = var.region
  force_destroy               = var.force_destroy_buckets
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  lifecycle_rule {
    condition {
      age = var.log_retention_days
    }
    action {
      type = "Delete"
    }
  }
}

resource "google_storage_bucket" "tempo" {
  name                        = "${var.project_id}-tempo"
  location                    = var.region
  force_destroy               = var.force_destroy_buckets
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  lifecycle_rule {
    condition {
      age = var.trace_retention_days
    }
    action {
      type = "Delete"
    }
  }
}

# --- Service accounts (identities for pods, via Workload Identity) ----------------------

resource "google_service_account" "loki" {
  account_id   = "shoplite-loki"
  display_name = "ShopLite Loki (GCS access)"
}

resource "google_service_account" "tempo" {
  account_id   = "shoplite-tempo"
  display_name = "ShopLite Tempo (GCS access)"
}

resource "google_service_account" "eso" {
  account_id   = "shoplite-eso"
  display_name = "ShopLite External Secrets (read Secret Manager)"
}

resource "google_storage_bucket_iam_member" "loki" {
  bucket = google_storage_bucket.loki.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.loki.email}"
}

resource "google_storage_bucket_iam_member" "tempo" {
  bucket = google_storage_bucket.tempo.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.tempo.email}"
}

# --- Secret Manager (shells only) --------------------------------------------------------

resource "google_secret_manager_secret" "shoplite" {
  for_each  = local.secret_names
  secret_id = each.key

  replication {
    user_managed {
      replicas {
        location = var.region
      }
    }
  }
}

# External Secrets may read each secret, nothing else in the project.
resource "google_secret_manager_secret_iam_member" "eso_read" {
  for_each  = local.secret_names
  secret_id = google_secret_manager_secret.shoplite[each.key].secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.eso.email}"
}
