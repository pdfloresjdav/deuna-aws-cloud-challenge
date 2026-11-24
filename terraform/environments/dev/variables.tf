# ---------------------------------------------------------------------------
# Common / metadata
# ---------------------------------------------------------------------------
variable "aws_region" {
  description = "AWS region (configurable example, NOT Deuna!'s actual region)."
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment name."
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "environment must be 'dev' or 'prod'."
  }
}

variable "application" {
  description = "Application/platform name used for naming and tagging."
  type        = string
  default     = "deuna"
}

variable "owner" {
  description = "Owning team."
  type        = string
  default     = "cloud-platform"
}

variable "cost_center" {
  description = "Cost center tag."
  type        = string
  default     = "platform-engineering"
}

variable "data_classification" {
  description = "Data classification tag for financial data."
  type        = string
  default     = "restricted"
}

# ---------------------------------------------------------------------------
# KMS
# ---------------------------------------------------------------------------
variable "kms_deletion_window_in_days" {
  description = "Recovery window before the workload key is deleted."
  type        = number
  default     = 7
}

variable "kms_key_administrator_arns" {
  description = "IAM principals allowed to administer the workload KMS key."
  type        = list(string)
  default     = []
}

variable "kms_key_consumer_arns" {
  description = "IAM principals allowed to use the workload KMS key cryptographically."
  type        = list(string)
  default     = []
}

# ---------------------------------------------------------------------------
# S3
# ---------------------------------------------------------------------------
variable "data_bucket_name" {
  description = "Globally unique bucket name for financial data."
  type        = string
}

variable "s3_force_destroy" {
  description = "Allow deletion of a non-empty bucket (dev convenience only)."
  type        = bool
  default     = false
}

variable "s3_noncurrent_version_expiration_days" {
  description = "Days before noncurrent object versions expire."
  type        = number
  default     = 90
}

# ---------------------------------------------------------------------------
# Networking (existing resources - placeholders in the example tfvars)
# ---------------------------------------------------------------------------
variable "vpc_id" {
  description = "Existing VPC ID."
  type        = string
}

variable "private_subnet_ids" {
  description = "Existing private subnet IDs in at least two AZs."
  type        = list(string)
}

variable "allowed_security_group_ids" {
  description = "Security groups allowed to reach PostgreSQL on 5432."
  type        = list(string)
  default     = []
}

# ---------------------------------------------------------------------------
# Aurora (dev defaults: single small instance, reduced monitoring)
# ---------------------------------------------------------------------------
variable "database_name" {
  description = "Initial database name."
  type        = string
  default     = "deuna"
}

variable "aurora_engine_version" {
  description = "Aurora PostgreSQL engine version."
  type        = string
  default     = "16.6"
}

variable "aurora_instance_class" {
  description = "Instance class (dev: small Graviton)."
  type        = string
  default     = "db.t4g.medium"
}

variable "aurora_instance_count" {
  description = "Number of instances (dev: 1)."
  type        = number
  default     = 1
}

variable "aurora_backup_retention_period" {
  description = "Backup retention in days (dev)."
  type        = number
  default     = 7
}

variable "aurora_deletion_protection" {
  description = "Deletion protection (dev: off for teardown)."
  type        = bool
  default     = false
}

variable "aurora_skip_final_snapshot" {
  description = "Skip final snapshot on deletion (dev: true)."
  type        = bool
  default     = true
}

variable "aurora_monitoring_interval" {
  description = "Enhanced Monitoring interval in seconds (dev: coarser)."
  type        = number
  default     = 60
}

variable "aurora_database_insights_mode" {
  description = "Database Insights mode (dev: standard)."
  type        = string
  default     = "standard"
}

variable "aurora_performance_insights_retention_period" {
  description = "Performance Insights retention in days (dev: 7, free)."
  type        = number
  default     = 7
}

variable "aurora_log_retention_days" {
  description = "CloudWatch Logs retention for PostgreSQL logs (dev)."
  type        = number
  default     = 30
}

# ---------------------------------------------------------------------------
# Secrets Manager
# ---------------------------------------------------------------------------
variable "secret_admin_principal_arns" {
  description = "IAM principals allowed to administer and read the pgadmin secret."
  type        = list(string)
  default     = []
}

variable "secret_consumer_principal_arns" {
  description = "IAM principals allowed to read the pgadmin secret value."
  type        = list(string)
  default     = []
}
