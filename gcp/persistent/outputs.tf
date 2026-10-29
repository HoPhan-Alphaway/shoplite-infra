output "loki_bucket" {
  value = google_storage_bucket.loki.name
}

output "tempo_bucket" {
  value = google_storage_bucket.tempo.name
}

output "gsa_emails" {
  description = "Google service accounts that Kubernetes ServiceAccounts impersonate (annotation iam.gke.io/gcp-service-account)."
  value = {
    loki  = google_service_account.loki.email
    tempo = google_service_account.tempo.email
    eso   = google_service_account.eso.email
  }
}

output "secret_names" {
  description = "Secret Manager secrets to fill with scripts/seed-secrets.sh."
  value       = sort(tolist(local.secret_names))
}
