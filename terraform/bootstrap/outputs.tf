output "state_bucket_name" {
  description = "Name of the Terraform state bucket (use as 'bucket' in backend config)."
  value       = aws_s3_bucket.state.id
}

output "state_bucket_arn" {
  description = "ARN of the Terraform state bucket."
  value       = aws_s3_bucket.state.arn
}

output "state_kms_key_arn" {
  description = "ARN of the state encryption key (use as 'kms_key_id' in backend config)."
  value       = aws_kms_key.state.arn
}

output "state_kms_alias" {
  description = "Alias of the state encryption key."
  value       = aws_kms_alias.state.name
}

output "backend_config_hint" {
  description = "Values to populate in each environment's backend.hcl."
  value = {
    bucket       = aws_s3_bucket.state.id
    region       = var.aws_region
    kms_key_id   = aws_kms_key.state.arn
    encrypt      = true
    use_lockfile = true
    dev_key      = "env/dev/terraform.tfstate"
    prod_key     = "env/prod/terraform.tfstate"
  }
}
