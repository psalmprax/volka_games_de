# terraform/modules/rds_postgres/main.tf
# Deploys a multi-AZ RDS PostgreSQL instance.

variable "project_name" {
  description = "A name for the project to prefix resources"
  type        = string
}

variable "vpc_id" {
  description = "The ID of the VPC to deploy the RDS instance into"
  type        = string
}

variable "private_subnet_ids" {
  description = "List of private subnet IDs for the DB subnet group (must be at least 2 for multi-AZ)"
  type        = list(string)
}

variable "db_name" {
  description = "Name for the RDS PostgreSQL database"
  type        = string
}

variable "db_username" {
  description = "Master username for the RDS PostgreSQL database"
  type        = string
}

variable "db_password_secret_arn" {
  description = "ARN of the Secrets Manager secret containing the DB master password"
  type        = string
}

variable "instance_class" {
  description = "Instance class for the RDS PostgreSQL database"
  type        = string
}

variable "allocated_storage" {
  description = "Allocated storage in GB for the RDS PostgreSQL database"
  type        = number
}

# Optional: KMS Key for RDS Encryption
# resource "aws_kms_key" "rds_encryption" {
#   description             = "${var.project_name}-rds-encryption-key"
#   deletion_window_in_days = 10 # Set based on policy
#   enable_key_rotation     = true
#   tags = { Name = "${var.project_name}-rds-encryption-key" }
# }

resource "aws_db_subnet_group" "main" {
  name       = "${var.project_name}-db-subnet-group"
  subnet_ids = var.private_subnet_ids

  tags = {
    Name = "${var.project_name}-db-subnet-group"
  }
}

resource "aws_security_group" "db_access" {
  name_prefix = "${var.project_name}-rds-access-"
  description = "Allow access to RDS PostgreSQL instance"
  vpc_id      = var.vpc_id

  # Ingress rules will be added by other modules (e.g., ETL, Airflow)
  # Example: Allow traffic from a specific security group (e.g., ETL task SG)
  # ingress {
  #   description = "Allow PostgreSQL from ETL tasks"
  #   from_port   = 5432
  #   to_port     = 5432
  #   protocol    = "tcp"
  #   security_groups = [module.iam.etl_task_security_group_id] # Assuming IAM module outputs this
  # }

  tags = { Name = "${var.project_name}-rds-access" }
}

resource "aws_db_instance" "main" {
  identifier              = "${var.project_name}-postgres"
  engine                  = "postgres"
  engine_version          = "14" # Or your desired version
  instance_class          = var.instance_class
  allocated_storage       = var.allocated_storage
  db_name                 = var.db_name
  username                = var.db_username
  password                = data.aws_secretsmanager_secret_version.db_password.secret_string
  db_subnet_group_name    = aws_db_subnet_group.main.name
  vpc_security_group_ids  = [aws_security_group.db_access.id]
  multi_az                = true # Production best practice
  skip_final_snapshot     = false # Set to false for production
  publicly_accessible     = false # Must be false in private subnets
  storage_encrypted       = true # Production best practice
  # kms_key_id              = aws_kms_key.rds_encryption.arn # If using a custom KMS key
  backup_retention_period = 7 # Or more for production
  preferred_backup_window = "03:00-04:00"
  preferred_maintenance_window = "Mon:05:00-Mon:06:00"
  deletion_protection     = true # Enable deletion protection for production databases
  # monitoring_interval     = 60 # Enable enhanced monitoring
  # performance_insights_enabled = true # Enable performance insights

  tags = {
    Name    = "${var.project_name}-postgres"
    Project = var.project_name
  }
}

# Data source to retrieve the DB password from Secrets Manager
data "aws_secretsmanager_secret_version" "db_password" {
  secret_id = var.db_password_secret_arn
}

output "db_instance_endpoint" {
  description = "The endpoint of the RDS instance"
  value       = aws_db_instance.main.address
}

output "db_instance_port" {
  description = "The port of the RDS instance"
  value       = aws_db_instance.main.port
}

output "db_security_group_id" {
  description = "The ID of the security group for the RDS instance"
  value       = aws_security_group.db_access.id
}