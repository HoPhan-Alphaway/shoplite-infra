variable "project_id" {
  type = string
}

variable "region" {
  type    = string
  default = "us-central1"
}

variable "zone" {
  description = "One zone only: a zonal cluster gets the GKE free-tier credit for its management fee."
  type        = string
  default     = "us-central1-a"
}

variable "cluster_name" {
  type    = string
  default = "shoplite"
}

# Sizing (measured on k3d, see learning/phase-6-gke-phan-tich.md section 12):
# dev + prod needs about 12 GB RAM and 3 vCPU of requests. Free-trial quotas cap the
# project at 12 vCPU in total and 4 in-use IP addresses (one per node + the Kong load balancer).
variable "machine_type" {
  type    = string
  default = "n2-standard-4"
}

variable "node_count" {
  type    = number
  default = 2
}

variable "disk_size_gb" {
  type    = number
  default = 50
}

variable "subnet_cidr" {
  type    = string
  default = "10.10.0.0/20"
}

variable "pods_cidr" {
  type    = string
  default = "10.20.0.0/16"
}

variable "services_cidr" {
  type    = string
  default = "10.30.0.0/20"
}

# Kubernetes ServiceAccount -> Google service account (created in gcp/persistent).
# The KSA names must match what the Helm charts create; verify when wiring each chart.
variable "workload_identity" {
  type = map(object({
    gsa       = string # account_id in gcp/persistent
    namespace = string
    ksa       = string
  }))
  default = {
    loki  = { gsa = "shoplite-loki", namespace = "observability", ksa = "loki" }
    tempo = { gsa = "shoplite-tempo", namespace = "observability", ksa = "tempo" }
    eso   = { gsa = "shoplite-eso", namespace = "external-secrets", ksa = "external-secrets" }
  }
}
