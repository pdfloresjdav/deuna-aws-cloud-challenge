# Restricted resource policy for the RDS-managed master user secret.
#
# Ownership & rotation: the secret is created, owned and rotated by RDS. RDS
# manages rotation natively (default schedule: every 7 days for managed master
# user passwords). This module intentionally adds ONLY Allow statements and no
# Deny, so it cannot interfere with the AWS-managed rotation Lambda. Public
# access is blocked via block_public_policy.
#
# IMPORTANT (not an exclusive allowlist): an Allow-only resource policy is
# ADDITIVE. It does NOT override other same-account IAM principals that already
# have identity-based permissions to the secret, and block_public_policy only
# rejects policies granting public/anonymous access - it is not a principal
# allowlist. Effective restriction of pgadmin access therefore depends on
# least-privilege IAM identity policies plus the KMS key policy (kms:Decrypt).
#
# Required permissions (document, not granted here):
#   - Terraform deploy identity: secretsmanager:PutResourcePolicy +
#     GetResourcePolicy on the secret (to manage this policy), and the RDS/KMS
#     permissions to create the cluster that owns the secret.
#   - Legitimate readers (admin_principal_arns / consumer_principal_arns):
#     secretsmanager:GetSecretValue + DescribeSecret, plus kms:Decrypt on the
#     workload CMK (via secretsmanager). Application microservices must NOT be
#     listed here and must use separate, least-privilege database identities -
#     never the pgadmin master credential.

locals {
  read_principals = distinct(concat(var.admin_principal_arns, var.consumer_principal_arns))
}

# The resource policy is ALWAYS created for the managed secret (at least one
# administrative principal is required - see variables.tf validation).
data "aws_iam_policy_document" "secret" {
  # checkov:skip=CKV_AWS_108:Resource-based SECRET policy. "*" denotes the secret this policy is attached to (secret_arn); access is constrained to the explicit authorized admin/consumer principal ARNs. This is not an identity-policy data-exfiltration path.
  # checkov:skip=CKV_AWS_109:Resource-based secret policy (see CKV_AWS_108). Permissions are limited to named principals.
  # checkov:skip=CKV_AWS_356:Resource "*" in a secret resource policy refers to the attached secret and cannot be narrowed further.
  statement {
    sid    = "AllowAuthorizedRead"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = local.read_principals
    }
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "AllowAdminManage"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = var.admin_principal_arns
    }
    actions = [
      "secretsmanager:GetResourcePolicy",
      "secretsmanager:PutResourcePolicy",
      "secretsmanager:DeleteResourcePolicy",
      "secretsmanager:ListSecretVersionIds",
    ]
    resources = ["*"]
  }
}

resource "aws_secretsmanager_secret_policy" "this" {
  secret_arn          = var.secret_arn
  policy              = data.aws_iam_policy_document.secret.json
  block_public_policy = var.block_public_policy

  lifecycle {
    precondition {
      condition     = length(var.admin_principal_arns) >= 1
      error_message = "At least one admin_principal_arns entry is required for the managed secret resource policy."
    }
  }
}
