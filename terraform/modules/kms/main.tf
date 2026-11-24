# Customer-managed symmetric KMS key for encryption at rest of workload data
# (Aurora storage, S3 objects, the RDS-managed secret and CloudWatch Logs).
#
# Key policy design (least privilege, separating administration from usage):
#   1. EnableIAMPermissions   - Delegates access control to IAM for the account
#                               root. This is the AWS-recommended anti-lockout
#                               safeguard: it keeps the key manageable via IAM
#                               policies and prevents an orphaned key. It is the
#                               controlled administration/recovery mechanism.
#   2. KeyAdministration      - Administrative actions for key admins ONLY. No
#                               Encrypt/Decrypt, enforcing separation of duties.
#   3. KeyUsage               - Cryptographic operations for key consumers,
#                               restricted to the authorized AWS services via
#                               kms:ViaService and the account via kms:CallerAccount.
#   4. AllowServiceGrants     - Consumers may create grants only on behalf of AWS
#                               resources (kms:GrantIsForAWSResource = true). This
#                               is how RDS and Secrets Manager obtain key access.
#   5. AllowCloudWatchLogs    - The CloudWatch Logs service principal may encrypt
#                               log groups, scoped by encryption context ARN.

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account_id   = data.aws_caller_identity.current.account_id
  partition    = data.aws_partition.current.partition
  via_services = [for s in var.workload_service_names : "${s}.${var.aws_region}.amazonaws.com"]
}

data "aws_iam_policy_document" "key" {
  # checkov:skip=CKV_AWS_109:This is a KMS KEY POLICY (resource-based). "*" denotes the key itself - key policies cannot scope Resource to an ARN. The root kms:* statement is the AWS-recommended anti-lockout/recovery safeguard; least privilege is enforced via the admin/usage split and ViaService/CallerAccount/GrantIsForAWSResource conditions.
  # checkov:skip=CKV_AWS_111:KMS key policy (resource-based); see CKV_AWS_109 rationale. Write/admin actions are constrained to key administrators, usage to consumers via service conditions.
  # checkov:skip=CKV_AWS_356:KMS key policy Resource "*" refers to the key the policy is attached to; it cannot be narrowed further for a key policy.
  # 1. Delegate control to IAM (anti-lockout / recovery safeguard).
  statement {
    sid    = "EnableIAMPermissions"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = ["arn:${local.partition}:iam::${local.account_id}:root"]
    }
    actions   = ["kms:*"]
    resources = ["*"]
  }

  # 2. Key administrators: management only, no cryptographic use.
  dynamic "statement" {
    for_each = length(var.key_administrator_arns) > 0 ? [1] : []
    content {
      sid    = "KeyAdministration"
      effect = "Allow"
      principals {
        type        = "AWS"
        identifiers = var.key_administrator_arns
      }
      actions = [
        "kms:Create*",
        "kms:Describe*",
        "kms:Enable*",
        "kms:List*",
        "kms:Put*",
        "kms:Update*",
        "kms:Revoke*",
        "kms:Disable*",
        "kms:Get*",
        "kms:Delete*",
        "kms:TagResource",
        "kms:UntagResource",
        "kms:ScheduleKeyDeletion",
        "kms:CancelKeyDeletion",
      ]
      resources = ["*"]
    }
  }

  # 3. Key consumers: cryptographic operations restricted to approved services.
  dynamic "statement" {
    for_each = length(var.key_consumer_arns) > 0 ? [1] : []
    content {
      sid    = "KeyUsage"
      effect = "Allow"
      principals {
        type        = "AWS"
        identifiers = var.key_consumer_arns
      }
      actions = [
        "kms:Encrypt",
        "kms:Decrypt",
        "kms:ReEncrypt*",
        "kms:GenerateDataKey*",
        "kms:DescribeKey",
      ]
      resources = ["*"]

      condition {
        test     = "StringEquals"
        variable = "kms:ViaService"
        values   = local.via_services
      }
      condition {
        test     = "StringEquals"
        variable = "kms:CallerAccount"
        values   = [local.account_id]
      }
    }
  }

  # 4. Consumers may only create grants for AWS resources (RDS, Secrets Manager).
  dynamic "statement" {
    for_each = length(var.key_consumer_arns) > 0 ? [1] : []
    content {
      sid    = "AllowServiceGrants"
      effect = "Allow"
      principals {
        type        = "AWS"
        identifiers = var.key_consumer_arns
      }
      actions = [
        "kms:CreateGrant",
        "kms:ListGrants",
        "kms:RevokeGrant",
      ]
      resources = ["*"]

      condition {
        test     = "Bool"
        variable = "kms:GrantIsForAWSResource"
        values   = ["true"]
      }
    }
  }

  # 5. CloudWatch Logs service principal (log group encryption).
  dynamic "statement" {
    for_each = var.enable_cloudwatch_logs_encryption ? [1] : []
    content {
      sid    = "AllowCloudWatchLogs"
      effect = "Allow"
      principals {
        type        = "Service"
        identifiers = ["logs.${var.aws_region}.amazonaws.com"]
      }
      actions = [
        "kms:Encrypt",
        "kms:Decrypt",
        "kms:ReEncrypt*",
        "kms:GenerateDataKey*",
        "kms:DescribeKey",
      ]
      resources = ["*"]

      condition {
        test     = "ArnLike"
        variable = "kms:EncryptionContext:aws:logs:arn"
        values   = ["arn:${local.partition}:logs:${var.aws_region}:${local.account_id}:log-group:*"]
      }
    }
  }
}

resource "aws_kms_key" "this" {
  description              = var.description
  deletion_window_in_days  = var.deletion_window_in_days
  enable_key_rotation      = var.enable_key_rotation
  key_usage                = "ENCRYPT_DECRYPT"
  customer_master_key_spec = "SYMMETRIC_DEFAULT"
  policy                   = data.aws_iam_policy_document.key.json

  tags = var.tags

  # Protect the workload key from accidental destruction via Terraform. This is
  # a literal (prevent_destroy cannot be a variable), so it applies to all
  # environments. Dev teardown requires temporarily removing this block in a
  # dedicated, reviewed change. NOTE: this only guards Terraform operations - it
  # does NOT protect against a direct AWS API ScheduleKeyDeletion or removal of
  # the resource block. Complementary production controls: IAM deny on
  # kms:ScheduleKeyDeletion for non-break-glass roles, and a CloudWatch alarm on
  # ScheduleKeyDeletion events (see docs/03-terraform-architecture.md §5).
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_kms_alias" "this" {
  name          = "alias/${var.alias_name}"
  target_key_id = aws_kms_key.this.key_id
}
