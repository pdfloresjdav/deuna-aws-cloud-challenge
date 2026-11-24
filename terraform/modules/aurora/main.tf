# Aurora PostgreSQL cluster for Deuna! workloads.
#
# Scope: this module consumes an EXISTING VPC and private subnets. It does NOT
# create a VPC, NAT Gateway, bastion host or application infrastructure.
#
# Security: storage encrypted with the workload KMS key, no public access,
# ingress only from approved security groups, TLS enforced via rds.force_ssl,
# master credentials managed natively by RDS + Secrets Manager (no plaintext).

data "aws_partition" "current" {}

locals {
  monitoring_enabled = var.monitoring_interval > 0
  log_group_name     = "/aws/rds/cluster/${var.cluster_identifier}/postgresql"
}

# Guard: advanced Database Insights requires Performance Insights with 465d retention.
check "database_insights_consistency" {
  assert {
    condition = var.database_insights_mode != "advanced" || (
      var.performance_insights_enabled && var.performance_insights_retention_period >= 465
    )
    error_message = "Advanced Database Insights requires performance_insights_enabled=true and retention >= 465 days."
  }
}

resource "aws_db_subnet_group" "this" {
  name       = "${var.cluster_identifier}-subnets"
  subnet_ids = var.subnet_ids
  tags       = var.tags
}

resource "aws_security_group" "db" {
  name        = "${var.cluster_identifier}-db-sg"
  description = "Aurora PostgreSQL access - ingress restricted to approved security groups"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.cluster_identifier}-db-sg" })
}

# PostgreSQL ingress only from explicitly approved security groups (no CIDR ranges).
resource "aws_vpc_security_group_ingress_rule" "postgres" {
  for_each = toset(var.allowed_security_group_ids)

  security_group_id            = aws_security_group.db.id
  description                  = "PostgreSQL from approved security group ${each.value}"
  referenced_security_group_id = each.value
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

# Egress is required for AWS service calls (KMS, Secrets Manager, monitoring).
resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.db.id
  description       = "Allow outbound to AWS service endpoints"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_rds_cluster_parameter_group" "this" {
  name        = "${var.cluster_identifier}-cluster-pg"
  family      = var.parameter_group_family
  description = "Cluster parameter group enforcing TLS for ${var.cluster_identifier}"

  # Enforce encrypted (TLS) connections at the engine level.
  parameter {
    name         = "rds.force_ssl"
    value        = "1"
    apply_method = "pending-reboot"
  }

  tags = var.tags
}

# Dedicated least-privilege role for Enhanced Monitoring.
data "aws_iam_policy_document" "monitoring_assume" {
  count = local.monitoring_enabled ? 1 : 0
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["monitoring.rds.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "enhanced_monitoring" {
  count              = local.monitoring_enabled ? 1 : 0
  name               = "${var.cluster_identifier}-rds-monitoring"
  assume_role_policy = data.aws_iam_policy_document.monitoring_assume[0].json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "enhanced_monitoring" {
  count      = local.monitoring_enabled ? 1 : 0
  role       = aws_iam_role.enhanced_monitoring[0].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

# Pre-create the log group so retention and KMS encryption are managed explicitly.
resource "aws_cloudwatch_log_group" "postgresql" {
  # checkov:skip=CKV_AWS_338:Log retention is a documented operational/cost tradeoff and is configurable per environment (dev 30d / prod 90d). 1-year retention is recommended for compliance but is not a verified Deuna! mandate (see docs/03-terraform-architecture.md §10, §17).
  name              = local.log_group_name
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn
  tags              = var.tags
}

# Unique suffix for the final snapshot to avoid naming collisions on re-creation.
resource "random_id" "final_snapshot" {
  byte_length = 4
  keepers = {
    cluster_identifier = var.cluster_identifier
  }
}

resource "aws_rds_cluster" "this" {
  # checkov:skip=CKV_AWS_139:Deletion protection is controlled per environment (prod=true, dev=false by design via var.deletion_protection) to allow dev teardown.
  # checkov:skip=CKV2_AWS_8:Point-in-time recovery is provided by native automated backups (backup_retention_period). A centralized AWS Backup plan is an org-level recommendation (see docs §9, §19), not enabled here to avoid an extra paid service.
  # checkov:skip=CKV2_AWS_27:Full query logging (log_statement=all) can capture sensitive financial data in CloudWatch. Targeted auditing (e.g. pgAudit with scoped configuration) is recommended for production instead (see docs §10).
  cluster_identifier = var.cluster_identifier
  engine             = "aurora-postgresql"
  engine_version     = var.engine_version
  database_name      = var.database_name
  port               = 5432

  # IAM database authentication (defense in depth alongside the managed secret).
  iam_database_authentication_enabled = true

  # Native master credential management: RDS creates and rotates the secret in
  # Secrets Manager, encrypted with the workload KMS key. No plaintext anywhere.
  master_username               = var.master_username
  manage_master_user_password   = true
  master_user_secret_kms_key_id = var.kms_key_arn

  storage_encrypted = true
  kms_key_id        = var.kms_key_arn

  db_subnet_group_name            = aws_db_subnet_group.this.name
  vpc_security_group_ids          = [aws_security_group.db.id]
  db_cluster_parameter_group_name = aws_rds_cluster_parameter_group.this.name

  backup_retention_period      = var.backup_retention_period
  preferred_backup_window      = var.preferred_backup_window
  preferred_maintenance_window = var.preferred_maintenance_window
  copy_tags_to_snapshot        = true

  enabled_cloudwatch_logs_exports = var.enabled_cloudwatch_logs_exports

  # Performance Insights / Database Insights configured at cluster level.
  database_insights_mode                = var.database_insights_mode
  performance_insights_enabled          = var.performance_insights_enabled
  performance_insights_kms_key_id       = var.performance_insights_enabled ? var.kms_key_arn : null
  performance_insights_retention_period = var.performance_insights_enabled ? var.performance_insights_retention_period : null

  deletion_protection       = var.deletion_protection
  skip_final_snapshot       = var.skip_final_snapshot
  final_snapshot_identifier = var.skip_final_snapshot ? null : "${var.cluster_identifier}-final-${random_id.final_snapshot.hex}"

  apply_immediately = var.apply_immediately

  tags = var.tags

  depends_on = [aws_cloudwatch_log_group.postgresql]
}

resource "aws_rds_cluster_instance" "this" {
  # checkov:skip=CKV_AWS_353:Performance Insights is configured at the cluster level via database_insights_mode / performance_insights_* on aws_rds_cluster (the supported location when Database Insights is enabled); it is intentionally not duplicated on the instance.
  count = var.instance_count

  identifier         = "${var.cluster_identifier}-${count.index + 1}"
  cluster_identifier = aws_rds_cluster.this.id
  engine             = aws_rds_cluster.this.engine
  engine_version     = aws_rds_cluster.this.engine_version
  instance_class     = var.instance_class

  db_subnet_group_name = aws_db_subnet_group.this.name
  publicly_accessible  = false

  # Lower promotion_tier = higher failover priority (instance 1 is the preferred writer).
  promotion_tier = count.index

  # Apply minor engine upgrades automatically during the maintenance window.
  auto_minor_version_upgrade = true

  monitoring_interval = var.monitoring_interval
  monitoring_role_arn = local.monitoring_enabled ? aws_iam_role.enhanced_monitoring[0].arn : null

  apply_immediately = var.apply_immediately

  tags = var.tags
}
