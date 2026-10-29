terraform {
  required_version = ">= 1.6"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6.0, < 8.0"
    }
  }

  # Same state bucket as gcp/persistent, different prefix:
  #   terraform init -backend-config=../backend.hcl -backend-config="prefix=cluster"
  backend "gcs" {}
}

provider "google" {
  project = var.project_id
  region  = var.region
}
