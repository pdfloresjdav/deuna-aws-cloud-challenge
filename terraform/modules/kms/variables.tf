# KMS module input variables.

variable "aws_region" {
  description = "AWS region where the key is used. Used to build kms:ViaService condition values."
  type        = string
}

variable "alias_name" {
  description = "KMS alias without the 'alias/' prefix (e.g. deuna-dev-workload)."
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9/_-]+$", var.alias_name))
    error_message = "alias_name may only contain alphanumeric characters, hyphens, underscores and slashes."
  }
}

variable "description" {
  description = "Human readable description of the key purpose."
  type        = string
  default     = "Workload customer-managed key for encryption at rest"
}

variable "deletion_window_in_days" {
  description = "Waiting period (in days) before the key is permanently deleted after a destroy. Acts as a recovery window."
  type        = number
  default     = 30

  validation {
    condition     = var.deletion_window_in_days >= 7 && var.deletion_window_in_days <= 30
    error_message = "deletion_window_in_days must be between 7 and 30."
  }
}

variable "enable_key_rotation" {
  description = "Enable automatic yearly rotation of the key material."
  type        = bool
  default     = true
}

variable "key_administrator_arns" {
  description = "IAM role/user ARNs allowed to administer the key (no cryptographic operations)."
  type        = list(string)
  default     = []
}

variable "key_consumer_arns" {
  description = "IAM role/user ARNs allowed to use the key for cryptographic operations (no administration)."
  type        = list(string)
  default     = []
}

variable "workload_service_names" {
  description = "AWS service short names allowed to use the key via kms:ViaService (e.g. rds, s3, secretsmanager)."
  type        = list(string)
  default     = ["rds", "s3", "secretsmanager"]
}

variable "enable_cloudwatch_logs_encryption" {
  description = "Add a key policy statement allowing the CloudWatch Logs service principal to use the key for log group encryption."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags applied to the key. Must include the standard financial-data tag set."
  type        = map(string)
  default     = {}
}
