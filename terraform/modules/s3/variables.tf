# S3 module input variables.

variable "bucket_name" {
  description = "Globally unique S3 bucket name for financial data."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.bucket_name))
    error_message = "bucket_name must be a valid S3 bucket name (3-63 chars, lowercase)."
  }
}

variable "kms_key_arn" {
  description = "ARN of the workload KMS key used for SSE-KMS encryption."
  type        = string
}

variable "force_destroy" {
  description = "Allow deletion of a non-empty bucket. Must stay false for production financial data."
  type        = bool
  default     = false
}

variable "min_tls_version" {
  description = "Minimum TLS version enforced by the bucket policy."
  type        = string
  default     = "1.2"
}

variable "transition_to_ia_days" {
  description = "Days after which current objects transition to STANDARD_IA."
  type        = number
  default     = 30
}

variable "enable_glacier_transition" {
  description = "Whether to transition older current objects to GLACIER."
  type        = bool
  default     = true
}

variable "transition_to_glacier_days" {
  description = "Days after which current objects transition to GLACIER."
  type        = number
  default     = 90
}

variable "noncurrent_version_transition_days" {
  description = "Days after which noncurrent versions transition to STANDARD_IA."
  type        = number
  default     = 30
}

variable "noncurrent_version_expiration_days" {
  description = "Days after which noncurrent versions are expired. Operational assumption, not a legal mandate."
  type        = number
  default     = 365
}

variable "abort_incomplete_multipart_days" {
  description = "Days after which incomplete multipart uploads are aborted."
  type        = number
  default     = 7
}

variable "tags" {
  description = "Tags applied to the bucket."
  type        = map(string)
  default     = {}
}
