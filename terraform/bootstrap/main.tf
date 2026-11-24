# Bootstrap: provisions the S3 bucket and dedicated KMS key that back the
# Terraform remote state for the dev and prod environments.
#
# State locking is handled natively by S3 (use_lockfile = true) in the
# environment backends - no DynamoDB table is created (the DynamoDB locking
# mechanism is deprecated for new implementations).

provider "aws" {
  region = var.aws_region
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
}

# ----------------------------------------------------------------------------
# Dedicated KMS key for state encryption (separate from the workload key).
# ----------------------------------------------------------------------------
data "aws_iam_policy_document" "state_key" {
  # checkov:skip=CKV_AWS_109:KMS key policy (resource-based). "*" is the key itself; root kms:* is the AWS anti-lockout safeguard. Usage is constrained to state_admin_arns via kms:ViaService s3.
  # checkov:skip=CKV_AWS_111:KMS key policy; see CKV_AWS_109 rationale.
  # checkov:skip=CKV_AWS_356:KMS key policy Resource "*" refers to the attached key and cannot be narrowed.
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

  dynamic "statement" {
    for_each = length(var.state_admin_arns) > 0 ? [1] : []
    content {
      sid    = "StateKeyAdministration"
      effect = "Allow"
      principals {
        type        = "AWS"
        identifiers = var.state_admin_arns
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
        values   = ["s3.${var.aws_region}.amazonaws.com"]
      }
    }
  }
}

resource "aws_kms_key" "state" {
  description             = "Terraform remote state encryption key"
  deletion_window_in_days = var.kms_deletion_window_in_days
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.state_key.json
  tags                    = var.tags

  # Protect the state encryption key: losing it makes the remote state
  # unrecoverable. prevent_destroy guards only Terraform operations; it does NOT
  # protect against a direct AWS API ScheduleKeyDeletion or removal of this
  # resource block. Authorized teardown requires temporarily removing this block
  # in a reviewed change (see docs/03-terraform-architecture.md §13).
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_kms_alias" "state" {
  name          = "alias/${var.kms_alias_name}"
  target_key_id = aws_kms_key.state.key_id
}

# ----------------------------------------------------------------------------
# S3 bucket for Terraform state.
# ----------------------------------------------------------------------------
resource "aws_s3_bucket" "state" {
  # checkov:skip=CKV_AWS_18:Access logging omitted to avoid a recursively-logged bucket; use CloudTrail data events for state access auditing (see docs §13).
  # checkov:skip=CKV_AWS_144:Cross-region replication for state is a DR option enabled with an explicit requirement; not added here to avoid an unrequested paid service.
  # checkov:skip=CKV2_AWS_62:No event-driven workflow consumes the state bucket.
  bucket        = var.state_bucket_name
  force_destroy = false

  # Protect the state bucket from accidental destruction.
  lifecycle {
    prevent_destroy = true
  }

  tags = var.tags
}

resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.state.arn
    }
    bucket_key_enabled = true
  }
}

# Minimal lifecycle: clean up incomplete multipart uploads. State object
# versions are intentionally retained (not expired) to preserve recoverability.
resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    id     = "abort-incomplete-multipart-uploads"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

data "aws_iam_policy_document" "state_bucket" {
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  statement {
    sid    = "DenyOutdatedTLS"
    effect = "Deny"
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]
    condition {
      test     = "NumericLessThan"
      variable = "s3:TlsVersion"
      values   = ["1.2"]
    }
  }
}

resource "aws_s3_bucket_policy" "state" {
  bucket     = aws_s3_bucket.state.id
  policy     = data.aws_iam_policy_document.state_bucket.json
  depends_on = [aws_s3_bucket_public_access_block.state]
}
