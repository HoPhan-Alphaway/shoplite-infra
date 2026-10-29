variable "project_id" {
  description = "GCP project that holds everything."
  type        = string
}

variable "region" {
  description = "Region for buckets and Secret Manager replicas."
  type        = string
  default     = "us-central1"
}

variable "log_retention_days" {
  description = "Safety-net lifecycle on the Loki bucket. Loki's own retention (72h) is what normally deletes chunks."
  type        = number
  default     = 7
}

variable "trace_retention_days" {
  description = "Safety-net lifecycle on the Tempo bucket. Tempo's own retention is 24h."
  type        = number
  default     = 3
}

variable "force_destroy_buckets" {
  description = "Let `terraform destroy` delete non-empty buckets. Their content (logs, traces) is disposable."
  type        = bool
  default     = true
}

variable "extra_secret_names" {
  description = "Additional Secret Manager secret names to create empty (values are never in Terraform)."
  type        = list(string)
  default     = []
}
