# ---------------------------------------------------------------------------
# Common / metadata
# ---------------------------------------------------------------------------
variable "aws_region" {
  description = "AWS region (configurable example, NOT Deuna!'s actual region)."
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment name (this root is production)."
  type        = string
  default     = "prod"

  validation {
    condition     = var.environment == "prod"
    error_message = "This is the production root; environment must be 'prod'."
  }
}

# Production guardrail override. Leave false for normal operation. Set to true
# ONLY in a reviewed, explicitly authorized teardown change together with the
# relaxed destructive settings (s3_force_destroy, aurora_deletion_protection,
# aurora_skip_final_snapshot). See docs/03-terraform-architecture.md (teardown).
variable "prod_teardown_authorized" {
  description = "Explicitly authorize relaxing destructive-protection guardrails for a reviewed teardown."
  type        = bool
  default     = false
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
  description = "IAM principals allowed to administer the workload KMS key. At least one required in prod."
  type        = list(string)
  default     = []

  validation {
    condition     = length(var.kms_key_administrator_arns) >= 1
    error_message = "Production requires at least one kms_key_administrator_arns entry."
  }
}

variable "kms_key_consumer_arns" {
  description = "IAM principals allowed to use the workload KMS key cryptographically. At least one required in prod."
  type        = list(string)
  default     = []

  validation {
    condition     = length(var.kms_key_consumer_arns) >= 1
    error_message = "Production requires at least one kms_key_consumer_arns entry."
  }
}

# ---------------------------------------------------------------------------
# S3
# ---------------------------------------------------------------------------
variable "data_bucket_name" {
  description = "Globally unique bucket name for financial data."
  type        = string
}

variable "s3_force_destroy" {
  description = "Allow deletion of a non-empty bucket. Must stay false in prod (unless an authorized teardown)."
  type        = bool
  default     = false

  validation {
    condition     = var.prod_teardown_authorized || var.s3_force_destroy == false
    error_message = "s3_force_destroy must be false in prod unless prod_teardown_authorized = true."
  }
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
    condition     = var.aurora_instance_count == floor(var.aurora_instance_count) && var.aurora_instance_count >= 2 && var.aurora_instance_count <= 15
    error_message = "Production aurora_instance_count must be an integer between 2 and 15 (writer + reader) for HA."
  }
}

variable "aurora_backup_retention_period" {
  description = "Backup retention in days (prod)."
  type        = number
  default     = 14
}

variable "aurora_deletion_protection" {
  description = "Deletion protection (prod: on, unless an authorized teardown)."
  type        = bool
  default     = true

  validation {
    condition     = var.prod_teardown_authorized || var.aurora_deletion_protection == true
    error_message = "aurora_deletion_protection must be true in prod unless prod_teardown_authorized = true."
  }
}

variable "aurora_skip_final_snapshot" {
  description = "Skip final snapshot on deletion (prod: false - snapshot required, unless an authorized teardown)."
  type        = bool
  default     = false

  validation {
    condition     = var.prod_teardown_authorized || var.aurora_skip_final_snapshot == false
    error_message = "aurora_skip_final_snapshot must be false in prod unless prod_teardown_authorized = true."
  }
}

variable "aurora_monitoring_interval" {
  description = "Enhanced Monitoring interval in seconds (prod: finer). Must stay enabled (> 0)."
  type        = number
  default     = 15

  validation {
    condition     = var.aurora_monitoring_interval > 0 && contains([1, 5, 10, 15, 30, 60], var.aurora_monitoring_interval)
    error_message = "Production Enhanced Monitoring must stay enabled: aurora_monitoring_interval must be one of 1,5,10,15,30,60."
  }
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
  description = "IAM principals allowed to administer and read the pgadmin secret. At least one required in prod."
  type        = list(string)
  default     = []

  validation {
    condition     = length(var.secret_admin_principal_arns) >= 1
    error_message = "Production requires at least one secret_admin_principal_arns entry."
  }
}

variable "secret_consumer_principal_arns" {
  description = "IAM principals allowed to read the pgadmin secret value."
  type        = list(string)
  default     = []
}
