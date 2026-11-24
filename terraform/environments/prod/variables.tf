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
  default     = "prod"

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
  description = "Recovery window before the workload key is deleted (prod: longer)."
  type        = number
  default     = 30
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
  description = "Allow deletion of a non-empty bucket. Must stay false in prod."
  type        = bool
  default     = false
}

variable "s3_noncurrent_version_expiration_days" {
  description = "Days before noncurrent object versions expire (prod: longer retention)."
  type        = number
  default     = 365
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
# Aurora (prod defaults: writer + reader across AZs, stricter protection)
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
  description = "Instance class (prod: memory-optimized Graviton)."
  type        = string
  default     = "db.r6g.large"
}

variable "aurora_instance_count" {
  description = "Number of instances (prod: >=2 for HA)."
  type        = number
  default     = 2

  validation {
    condition     = var.aurora_instance_count >= 2
    error_message = "Production must run at least 2 instances (writer + reader) for HA."
  }
}

variable "aurora_backup_retention_period" {
  description = "Backup retention in days (prod)."
  type        = number
  default     = 14
}

variable "aurora_deletion_protection" {
  description = "Deletion protection (prod: on)."
  type        = bool
  default     = true
}

variable "aurora_skip_final_snapshot" {
  description = "Skip final snapshot on deletion (prod: false - snapshot required)."
  type        = bool
  default     = false
}

variable "aurora_monitoring_interval" {
  description = "Enhanced Monitoring interval in seconds (prod: finer)."
  type        = number
  default     = 15
}

variable "aurora_database_insights_mode" {
  description = "Database Insights mode (prod: standard; set 'advanced' for 15-month retention)."
  type        = string
  default     = "standard"
}

variable "aurora_performance_insights_retention_period" {
  description = "Performance Insights retention in days (prod: 7 free; 465 required for advanced)."
  type        = number
  default     = 7
}

variable "aurora_log_retention_days" {
  description = "CloudWatch Logs retention for PostgreSQL logs (prod)."
  type        = number
  default     = 90
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
