# Restricted resource policy for the RDS-managed master user secret.
#
# Ownership & rotation: the secret is created, owned and rotated by RDS. RDS
# manages rotation natively (default schedule: every 7 days for managed master
# user passwords). This module intentionally adds ONLY Allow statements and no
# Deny, so it cannot interfere with the AWS-managed rotation Lambda. Public
# access is blocked via block_public_policy. Primary access restriction is
# enforced by least-privilege IAM identity policies and the KMS key policy
# (defense in depth); this resource policy is an explicit allow-list for the
# authorized administrative identities.

locals {
  read_principals = distinct(concat(var.admin_principal_arns, var.consumer_principal_arns))
  manage_policy   = length(var.admin_principal_arns) > 0 || length(var.consumer_principal_arns) > 0
}

data "aws_iam_policy_document" "secret" {
  count = local.manage_policy ? 1 : 0

  dynamic "statement" {
    for_each = length(local.read_principals) > 0 ? [1] : []
    content {
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
  }

  dynamic "statement" {
    for_each = length(var.admin_principal_arns) > 0 ? [1] : []
    content {
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
}

resource "aws_secretsmanager_secret_policy" "this" {
  count = local.manage_policy ? 1 : 0

  secret_arn          = var.secret_arn
  policy              = data.aws_iam_policy_document.secret[0].json
  block_public_policy = var.block_public_policy
}
