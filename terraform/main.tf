provider "aws" {
  region = var.aws_region
}

module "vpc" {
  source = "./modules/vpc"
  project_name = var.project_name
  vpc_cidr     = var.vpc_cidr
  # public_subnet_cidrs = var.public_subnet_cidrs # Use defaults or pass variables
  # private_subnet_cidrs = var.private_subnet_cidrs
}

module "rds_postgres" {
  source = "./modules/rds_postgres"
  
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids
  db_name            = var.db_name
  db_username        = var.db_username
  db_password_secret_arn = aws_secretsmanager_secret.rds_master_password.arn
  # The instance class is parameterized. For development, a cost-effective 'db.t4g.small' (Graviton) is a good default.
  # For production, you might override this with a value like 'db.m7g.large'.
  instance_class     = var.db_instance_class
  allocated_storage  = var.db_allocated_storage
}

resource "aws_secretsmanager_secret" "api_key_secret" {
  name        = var.api_key_secret_name
  description = "Volka SDE Test API Key"
  # The secret value should be populated manually via AWS console/CLI or a secure automated process.
  # Example: `aws secretsmanager put-secret-value --secret-id test/sde_api/key --secret-string '{"x-api-key":"YOUR_KEY_HERE"}'`
  # Avoid hardcoding sensitive values in Terraform.
  lifecycle {
    prevent_destroy = true # Prevent accidental deletion of this critical secret.
  }
}

# AWS Secrets Manager for RDS Master Password
resource "aws_secretsmanager_secret" "rds_master_password" {
  name        = "${var.project_name}-rds-master-password"
  description = "Master password for RDS instance for ${var.project_name}"
  recovery_window_in_days = 0 # Set to 0 to allow immediate deletion without recovery during testing. For prod, use 7-30.
  lifecycle {
    prevent_destroy = true # Good practice for secrets in production
  }
}

resource "aws_s3_bucket" "data_pipeline_bucket" {
  bucket = var.s3_bucket_name

  versioning {
    enabled = true
  }

  server_side_encryption_configuration {
    rule {
      apply_server_side_encryption_by_default {
        sse_algorithm = "AES256"
      }
    }
  }
}

# IAM Roles and Policies
module "iam" {
  source = "./modules/iam"
  project_name          = var.project_name
  db_password_secret_arn = aws_secretsmanager_secret.rds_master_password.arn
  api_key_secret_arn    = aws_secretsmanager_secret.api_key_secret.arn
  s3_bucket_arn         = aws_s3_bucket.data_pipeline_bucket.arn # Pass S3 ARN to IAM module if it needs S3 permissions
}

# ECS Cluster and Fargate Service for Airflow (Celery Executor)
# This module provisions a complete Airflow environment on Fargate.
# Consider using AWS Managed Workflows for Apache Airflow (MWAA) for a simpler, managed setup.
module "airflow_on_fargate" {
  source = "./modules/ecs_fargate_airflow"
  project_name         = var.project_name
  vpc_id               = module.vpc.vpc_id
  private_subnet_ids   = module.vpc.private_subnet_ids
  public_subnet_ids    = module.vpc.public_subnet_ids # Needed for ALB if used
  etl_task_role_arn    = module.iam.etl_task_role_arn
  # s3_bucket_name     = aws_s3_bucket.data_pipeline_bucket.bucket # For DAGs - This is not used in the module
  db_instance_endpoint = module.rds_postgres.db_instance_endpoint
  db_instance_port   = module.rds_postgres.db_instance_port
  db_security_group_id = module.rds_postgres.db_security_group_id
  airflow_docker_image = var.airflow_docker_image
  db_name              = var.db_name
  db_username          = var.db_username
  db_password_secret_arn = aws_secretsmanager_secret.rds_master_password.arn # Pass RDS password secret ARN
  api_key_secret_name  = var.api_key_secret_name
  acm_certificate_arn  = var.acm_certificate_arn
  aws_region           = var.aws_region
}