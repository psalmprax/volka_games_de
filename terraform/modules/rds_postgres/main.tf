/*
Module: rds_postgres
Description: Provisions a highly available, multi-AZ AWS RDS PostgreSQL instance.
It includes a dedicated DB subnet group, a security group, and integrates with
AWS Secrets Manager for password management and optional KMS for encryption.
*/

variable "project_name" {
  description = "The name of the project, used to prefix resource names for identification."
  type        = string
}

variable "vpc_id" {
  description = "The ID of the VPC where the RDS instance will be deployed."
  type        = string
}

variable "private_subnet_ids" {
  description = "A list of private subnet IDs for the DB subnet group. Must contain at least 2 subnets for multi-AZ."
  type        = list(string)
}

variable "db_name" {
  description = "The name for the initial database created in the RDS instance."
  type        = string
}

variable "db_username" {
  description = "The master username for the RDS instance."
  type        = string
}

variable "db_password_secret_arn" {
  description = "The ARN of the AWS Secrets Manager secret containing the master password for the database."
  type        = string
}

variable "instance_class" {
  description = "The instance class for the RDS instance (e.g., db.t3.micro)."
  type        = string
}

variable "allocated_storage" {
  description = "The allocated storage in gigabytes for the RDS instance."
  type        = number
}

variable "engine_version" {
  description = "The version number of the PostgreSQL engine to use."
  type        = string
  default     = "14.5"
}

variable "enable_kms_encryption" {
  description = "Set to true to create and use a customer-managed KMS key for database encryption."
  type        = bool
  default     = false
}

variable "enable_performance_insights" {
  description = "Set to true to enable Performance Insights for the database instance."
  type        = bool
  default     = true
}

variable "monitoring_interval" {
  description = "The interval, in seconds, for collecting enhanced monitoring metrics. Set to 0 to disable."
  type        = number
  default     = 60
}

# Conditionally creates a customer-managed KMS key for RDS encryption if enabled.
resource "aws_kms_key" "rds_encryption" {
  count                   = var.enable_kms_encryption ? 1 : 0
  description             = "${var.project_name}-rds-encryption-key"
  deletion_window_in_days = 10
  enable_key_rotation     = true

  tags = {
    Name = "${var.project_name}-rds-encryption-key"
  }
}

resource "aws_db_subnet_group" "main" {
  name       = "${var.project_name}-db-subnet-group"
  subnet_ids = var.private_subnet_ids

  tags = {
    Name = "${var.project_name}-db-subnet-group"
  }
}

resource "aws_security_group" "db_access" {
  name_prefix = "${var.project_name}-rds-access-"
  description = "Controls access to the RDS PostgreSQL instance. Allows traffic on port 5432."
  vpc_id      = var.vpc_id

  # By default, this security group has no ingress rules. It is intended that other
  # resources (e.g., an application's security group) will be configured to allow
  # outbound traffic to this security group on port 5432.

  tags = { Name = "${var.project_name}-rds-access" }
}

resource "aws_db_instance" "main" {
  identifier              = "${var.project_name}-postgres"
  engine                  = "postgres"
  engine_version          = var.engine_version
  instance_class          = var.instance_class
  allocated_storage       = var.allocated_storage
  db_name                 = var.db_name
  username                = var.db_username
  password                = data.aws_secretsmanager_secret_version.db_password.secret_string
  db_subnet_group_name    = aws_db_subnet_group.main.name
  vpc_security_group_ids  = [aws_security_group.db_access.id]
  multi_az                = true      # Provides high availability by provisioning a standby in a different AZ.
  skip_final_snapshot     = false     # Ensures a final snapshot is taken on deletion, crucial for data recovery.
  publicly_accessible     = false     # Best practice: database should not be exposed to the public internet.
  storage_encrypted       = true      # Encrypts the database at rest, a security best practice.
  kms_key_id              = var.enable_kms_encryption ? aws_kms_key.rds_encryption[0].arn : null
  backup_retention_period = 7         # Number of days to retain automated backups.
  preferred_backup_window = "03:00-04:00"
  preferred_maintenance_window = "Mon:05:00-Mon:06:00"
  deletion_protection     = true      # Protects the database from accidental deletion via the AWS console or API.
  monitoring_interval     = var.monitoring_interval
  performance_insights_enabled = var.enable_performance_insights

  tags = {
    Name    = "${var.project_name}-postgres"
    Project = var.project_name
  }
}

# Retrieves the master password for the database from AWS Secrets Manager.
# This avoids storing sensitive credentials directly in the Terraform state.
data "aws_secretsmanager_secret_version" "db_password" {
  secret_id = var.db_password_secret_arn
}

# --- Module Outputs ---

output "db_instance_endpoint" {
  description = "The connection endpoint for the RDS instance."
  value       = aws_db_instance.main.address
}

output "db_instance_port" {
  description = "The connection port for the RDS instance."
  value       = aws_db_instance.main.port
}

output "db_security_group_id" {
  description = "The ID of the security group attached to the RDS instance, to be used in other security group rules."
  value       = aws_security_group.db_access.id
}