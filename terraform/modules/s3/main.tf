# Secure S3 bucket for financial data.
#
# Controls:
#   - SSE-KMS with the workload key + S3 Bucket Keys (reduces KMS request cost).
#   - Versioning enabled; lifecycle for cost optimisation and version cleanup.
#   - All public access blocked; ACLs disabled (BucketOwnerEnforced).
#   - Bucket policy denies insecure transport, outdated TLS, and any explicitly
#     requested encryption that is not SSE-KMS with the workload key. Requests
#     that omit the encryption header are allowed and fall back to the bucket's
#     default SSE-KMS configuration (enforced by the StringNotEquals + Null pair,
#     which only denies when the header is present but incorrect).

resource "aws_s3_bucket" "this" {
  # checkov:skip=CKV_AWS_18:Server access logging is omitted to avoid a second (recursively-logged) bucket. Access/audit is recommended via CloudTrail S3 data events (see docs §6).
  # checkov:skip=CKV_AWS_144:Cross-region replication is a DR control enabled only with an explicit DR/compliance requirement; not added here to avoid an unrequested paid service (see docs §19).
  # checkov:skip=CKV2_AWS_62:No event-driven workflow consumes this bucket; event notifications would have no subscriber.
  bucket        = var.bucket_name
  force_destroy = var.force_destroy

  tags = var.tags
}

resource "aws_s3_bucket_ownership_controls" "this" {
  bucket = aws_s3_bucket.this.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket                  = aws_s3_bucket.this.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "this" {
  bucket = aws_s3_bucket.this.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  bucket = aws_s3_bucket.this.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
    # S3 Bucket Keys drastically reduce KMS API calls (and cost) for SSE-KMS.
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  # Explicit to avoid provider warnings about the default minimum object size.
  transition_default_minimum_object_size = "all_storage_classes_128K"

  rule {
    id     = "financial-data-lifecycle"
    status = "Enabled"

    filter {}

    transition {
      days          = var.transition_to_ia_days
      storage_class = "STANDARD_IA"
    }

    dynamic "transition" {
      for_each = var.enable_glacier_transition ? [1] : []
      content {
        days          = var.transition_to_glacier_days
        storage_class = "GLACIER"
      }
    }

    noncurrent_version_transition {
      noncurrent_days = var.noncurrent_version_transition_days
      storage_class   = "STANDARD_IA"
    }

    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_version_expiration_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = var.abort_incomplete_multipart_days
    }
  }
}

data "aws_iam_policy_document" "bucket" {
  # Deny any request not using TLS.
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.this.arn, "${aws_s3_bucket.this.arn}/*"]
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  # Deny connections below the minimum TLS version.
  statement {
    sid    = "DenyOutdatedTLS"
    effect = "Deny"
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.this.arn, "${aws_s3_bucket.this.arn}/*"]
    condition {
      test     = "NumericLessThan"
      variable = "s3:TlsVersion"
      values   = [var.min_tls_version]
    }
  }

  # Reject uploads that explicitly request a non-KMS algorithm.
  statement {
    sid    = "DenyIncorrectEncryptionAlgorithm"
    effect = "Deny"
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.this.arn}/*"]
    condition {
      test     = "StringNotEquals"
      variable = "s3:x-amz-server-side-encryption"
      values   = ["aws:kms"]
    }
    # Only applies when the header is present; omitted headers use the default.
    condition {
      test     = "Null"
      variable = "s3:x-amz-server-side-encryption"
      values   = ["false"]
    }
  }

  # Reject uploads that explicitly request a KMS key other than the workload key.
  statement {
    sid    = "DenyUnauthorizedKmsKey"
    effect = "Deny"
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.this.arn}/*"]
    condition {
      test     = "StringNotEquals"
      variable = "s3:x-amz-server-side-encryption-aws-kms-key-id"
      values   = [var.kms_key_arn]
    }
    condition {
      test     = "Null"
      variable = "s3:x-amz-server-side-encryption-aws-kms-key-id"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "this" {
  bucket = aws_s3_bucket.this.id
  policy = data.aws_iam_policy_document.bucket.json

  # Ensure public access block is applied before the policy is evaluated.
  depends_on = [aws_s3_bucket_public_access_block.this]
}
