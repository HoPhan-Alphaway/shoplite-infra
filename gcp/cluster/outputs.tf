output "cluster_name" {
  value = google_container_cluster.shoplite.name
}

output "zone" {
  value = var.zone
}

output "get_credentials" {
  description = "Run this to point kubectl at the new cluster."
  value       = "gcloud container clusters get-credentials ${google_container_cluster.shoplite.name} --zone ${var.zone} --project ${var.project_id}"
}

output "workload_pool" {
  value = "${var.project_id}.svc.id.goog"
}
