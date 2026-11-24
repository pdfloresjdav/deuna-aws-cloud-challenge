locals {
  name_prefix = "${var.application}-${var.environment}"

  common_tags = {
    Application        = var.application
    Environment        = var.environment
    Owner              = var.owner
    ManagedBy          = "terraform"
    CostCenter         = var.cost_center
    DataClassification = var.data_classification
  }
}

module "kms" {
  source = "../../modules/kms"

  aws_region                        = var.aws_region
  alias_name                        = "${local.name_prefix}-workload"
  description                       = "Workload CMK for ${local.name_prefix}"
  deletion_window_in_days           = var.kms_deletion_window_in_days
  key_administrator_arns            = var.kms_key_administrator_arns
  key_consumer_arns                 = var.kms_key_consumer_arns
  enable_cloudwatch_logs_encryption = true

  tags = local.common_tags
}

module "s3" {
  source = "../../modules/s3"

  bucket_name                        = var.data_bucket_name
  kms_key_arn                        = module.kms.key_arn
  force_destroy                      = var.s3_force_destroy
  noncurrent_version_expiration_days = var.s3_noncurrent_version_expiration_days

  tags = local.common_tags
}

module "aurora" {
  source = "../../modules/aurora"

  cluster_identifier = "${local.name_prefix}-aurora"
  engine_version     = var.aurora_engine_version
  instance_class     = var.aurora_instance_class
  instance_count     = var.aurora_instance_count
  database_name      = var.database_name

  kms_key_arn = module.kms.key_arn

  vpc_id                     = var.vpc_id
  subnet_ids                 = var.private_subnet_ids
  allowed_security_group_ids = var.allowed_security_group_ids

  backup_retention_period               = var.aurora_backup_retention_period
  deletion_protection                   = var.aurora_deletion_protection
  skip_final_snapshot                   = var.aurora_skip_final_snapshot
  monitoring_interval                   = var.aurora_monitoring_interval
  database_insights_mode                = var.aurora_database_insights_mode
  performance_insights_retention_period = var.aurora_performance_insights_retention_period
  log_retention_days                    = var.aurora_log_retention_days

  tags = local.common_tags
}

module "secrets_manager" {
  source = "../../modules/secrets-manager"

  secret_arn              = module.aurora.master_user_secret_arn
  admin_principal_arns    = var.secret_admin_principal_arns
  consumer_principal_arns = var.secret_consumer_principal_arns
}
