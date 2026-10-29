terraform {
  required_version = ">= 1.6"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6.0, < 8.0"
    }
  }

  # State lives in a GCS bucket created once by scripts/bootstrap-state.sh.
  # Bucket name is passed at init time so it is not hard-coded here:
  #   terraform init -backend-config=../backend.hcl -backend-config="prefix=persistent"
  backend "gcs" {}
}

provider "google" {
  project = var.project_id
  region  = var.region
}
