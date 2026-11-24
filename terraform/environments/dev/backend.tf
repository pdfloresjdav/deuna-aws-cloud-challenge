terraform {
  # Partial backend configuration. Provide concrete values via backend.hcl:
  #   terraform init -backend-config=backend.hcl
  # For local validation without a backend:
  #   terraform init -backend=false
  backend "s3" {}
}
