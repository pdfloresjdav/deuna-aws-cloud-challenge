# Non-sensitive infrastructure metadata. No secret values are exposed.

output "kms_key_arn" {
  description = "Workload KMS key ARN."
  value       = module.kms.key_arn
}

output "kms_alias" {
  description = "Workload KMS alias."
  value       = module.kms.alias_name
}

output "data_bucket_name" {
  description = "Financial data bucket name."
  value       = module.s3.bucket_id
}

output "aurora_cluster_endpoint" {
  description = "Aurora writer endpoint."
  value       = module.aurora.cluster_endpoint
}

output "aurora_reader_endpoint" {
  description = "Aurora reader endpoint."
  value       = module.aurora.reader_endpoint
}

output "aurora_instance_count" {
  description = "Number of Aurora instances."
  value       = module.aurora.instance_count
}

output "aurora_security_group_id" {
  description = "Database security group ID."
  value       = module.aurora.security_group_id
}

output "master_user_secret_arn" {
  description = "ARN (reference only) of the RDS-managed pgadmin secret."
  value       = module.aurora.master_user_secret_arn
}

output "cloudwatch_log_group_name" {
  description = "PostgreSQL CloudWatch log group."
  value       = module.aurora.cloudwatch_log_group_name
}
