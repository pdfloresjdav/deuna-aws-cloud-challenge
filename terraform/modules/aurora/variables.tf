# Aurora PostgreSQL module input variables.

variable "cluster_identifier" {
  description = "Identifier for the Aurora cluster (e.g. deuna-dev-aurora)."
  type        = string
}

variable "engine_version" {
  description = "Aurora PostgreSQL engine version. Verify availability with 'aws rds describe-db-engine-versions'."
  type        = string
  default     = "16.6"
}

variable "parameter_group_family" {
  description = "Cluster parameter group family matching the engine major version."
  type        = string
  default     = "aurora-postgresql16"
}

variable "instance_class" {
  description = "Instance class for cluster instances (Graviton classes recommended for cost/performance)."
  type        = string
  default     = "db.t4g.medium"
}

variable "instance_count" {
  description = "Number of cluster instances. 1 for dev, >=2 for production HA."
  type        = number
  default     = 1

  validation {
    condition     = var.instance_count >= 1 && var.instance_count <= 15
    error_message = "instance_count must be between 1 and 15."
  }
}

variable "database_name" {
  description = "Initial database name."
  type        = string
  default     = "deuna"
}

variable "master_username" {
  description = "Master username. The assessment mandates pgadmin."
  type        = string
  default     = "pgadmin"

  validation {
    condition     = var.master_username == "pgadmin"
    error_message = "master_username must be 'pgadmin' as required by the assessment."
  }
}

variable "kms_key_arn" {
  description = "Workload KMS key ARN used for storage, the managed secret, Performance Insights and logs."
  type        = string
}

variable "vpc_id" {
  description = "Existing VPC ID where the database security group is created."
  type        = string
}

variable "subnet_ids" {
  description = "Existing private subnet IDs (at least two AZs) for the DB subnet group."
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 2
    error_message = "At least two subnet IDs in different AZs are required for Aurora."
  }
}

variable "allowed_security_group_ids" {
  description = "Security group IDs allowed to connect to PostgreSQL on 5432 (application/admin tiers)."
  type        = list(string)
  default     = []
}

variable "backup_retention_period" {
  description = "Automated backup retention in days. Operational assumption, not a verified Deuna! requirement."
  type        = number
  default     = 7

  validation {
    condition     = var.backup_retention_period >= 1 && var.backup_retention_period <= 35
    error_message = "backup_retention_period must be between 1 and 35 days."
  }
}

variable "preferred_backup_window" {
  description = "Daily backup window (UTC)."
  type        = string
  default     = "03:00-04:00"
}

variable "preferred_maintenance_window" {
  description = "Weekly maintenance window (UTC)."
  type        = string
  default     = "sun:04:30-sun:05:30"
}

variable "deletion_protection" {
  description = "Protect the cluster from deletion. Must be true in production."
  type        = bool
  default     = false
}

variable "skip_final_snapshot" {
  description = "Skip the final snapshot on deletion. Must be false in production."
  type        = bool
  default     = true
}

variable "monitoring_interval" {
  description = "Enhanced Monitoring granularity in seconds (0 disables). Use 0,1,5,10,15,30,60."
  type        = number
  default     = 60

  validation {
    condition     = contains([0, 1, 5, 10, 15, 30, 60], var.monitoring_interval)
    error_message = "monitoring_interval must be one of 0, 1, 5, 10, 15, 30, 60."
  }
}

variable "performance_insights_enabled" {
  description = "Enable Performance Insights (required for Database Insights)."
  type        = bool
  default     = true
}

variable "database_insights_mode" {
  description = "CloudWatch Database Insights mode: 'standard' (cost-conscious) or 'advanced'."
  type        = string
  default     = "standard"

  validation {
    condition     = contains(["standard", "advanced"], var.database_insights_mode)
    error_message = "database_insights_mode must be 'standard' or 'advanced'."
  }
}

variable "performance_insights_retention_period" {
  description = "Performance Insights retention in days. 7 is free (standard); advanced requires 465."
  type        = number
  default     = 7
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention for exported PostgreSQL logs."
  type        = number
  default     = 30
}

variable "enabled_cloudwatch_logs_exports" {
  description = "Log types exported to CloudWatch Logs."
  type        = list(string)
  default     = ["postgresql"]
}

variable "apply_immediately" {
  description = "Apply changes immediately instead of during the maintenance window."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default     = {}
}
