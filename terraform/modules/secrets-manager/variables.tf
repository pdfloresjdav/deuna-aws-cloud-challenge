# Secrets Manager module input variables.
#
# This module does NOT create a secret. The pgadmin secret is created and owned
# by RDS (manage_master_user_password). This module manages a restricted
# resource policy on that managed secret and documents its rotation behaviour.

variable "secret_arn" {
  description = "ARN of the RDS-managed master user secret (from the aurora module)."
  type        = string
}

variable "admin_principal_arns" {
  description = "IAM principals allowed to administer the secret policy and read the secret (DBAs/operators). At least one is required."
  type        = list(string)
  default     = []

  validation {
    condition     = length(var.admin_principal_arns) >= 1
    error_message = "At least one admin_principal_arns entry is required (the resource policy is always created)."
  }
}

variable "consumer_principal_arns" {
  description = "IAM principals allowed to read the secret value (authorized administrative clients)."
  type        = list(string)
  default     = []
}

variable "block_public_policy" {
  description = "Reject any resource policy that would grant public access."
  type        = bool
  default     = true
}
