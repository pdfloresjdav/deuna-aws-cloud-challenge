output "cluster_identifier" {
  description = "Aurora cluster identifier."
  value       = aws_rds_cluster.this.cluster_identifier
}

output "cluster_arn" {
  description = "Aurora cluster ARN."
  value       = aws_rds_cluster.this.arn
}

output "cluster_endpoint" {
  description = "Writer endpoint."
  value       = aws_rds_cluster.this.endpoint
}

output "reader_endpoint" {
  description = "Reader endpoint (load-balanced across readers)."
  value       = aws_rds_cluster.this.reader_endpoint
}

output "port" {
  description = "Database port."
  value       = aws_rds_cluster.this.port
}

output "database_name" {
  description = "Initial database name."
  value       = aws_rds_cluster.this.database_name
}

output "security_group_id" {
  description = "ID of the database security group."
  value       = aws_security_group.db.id
}

output "instance_count" {
  description = "Number of provisioned cluster instances."
  value       = var.instance_count
}

output "cloudwatch_log_group_name" {
  description = "CloudWatch log group for PostgreSQL logs."
  value       = aws_cloudwatch_log_group.postgresql.name
}

# ARN of the RDS-managed master user secret. Non-sensitive: it is a reference,
# not the secret value. The value is never read into Terraform state.
output "master_user_secret_arn" {
  description = "ARN of the RDS-managed master user secret."
  value       = try(aws_rds_cluster.this.master_user_secret[0].secret_arn, null)
}

output "master_user_secret_kms_key_id" {
  description = "KMS key ID protecting the managed master user secret."
  value       = try(aws_rds_cluster.this.master_user_secret[0].kms_key_id, null)
}
