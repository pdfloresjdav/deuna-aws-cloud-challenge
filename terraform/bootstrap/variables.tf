variable "aws_region" {
  description = "AWS region for the Terraform state bucket and KMS key."
  type        = string
  default     = "us-east-1"
}

variable "state_bucket_name" {
  description = "Globally unique name for the Terraform remote state bucket."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.state_bucket_name))
    error_message = "state_bucket_name must be a valid S3 bucket name."
  }
}

variable "kms_alias_name" {
  description = "Alias (without alias/ prefix) for the state encryption key."
  type        = string
  default     = "deuna-tfstate"
}

variable "kms_deletion_window_in_days" {
  description = "Recovery window before the state KMS key is deleted."
  type        = number
  default     = 30
}

variable "state_admin_arns" {
  description = "IAM principal ARNs allowed to administer the state KMS key (CI/CD and operators)."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Common tags for bootstrap resources."
  type        = map(string)
  default = {
    Application        = "deuna-platform"
    Environment        = "shared"
    Owner              = "cloud-platform"
    ManagedBy          = "terraform"
    CostCenter         = "platform-engineering"
    DataClassification = "confidential"
  }
}
