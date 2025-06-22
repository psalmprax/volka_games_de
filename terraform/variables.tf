# /home/psalmprax/DEVELOPMENT_ENV/volka_games_de/terraform/variables.tf

variable "aws_region" {
  description = "The AWS region to deploy resources into."
  type        = string
  default     = "eu-central-1"
}

variable "project_name" {
  description = "A unique name for the project to prefix resources."
  type        = string
  default     = "volka-de-pipeline"
}

variable "vpc_cidr" {
  description = "The CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "db_name" {
  description = "The name for the RDS database."
  type        = string
  default     = "airflow_db"
}

variable "db_username" {
  description = "The username for the RDS database."
  type        = string
  default     = "airflow_user"
}

variable "db_instance_class" {
  description = "The instance class for the RDS PostgreSQL instance."
  type        = string
  default     = "db.t4g.small"
}

variable "db_allocated_storage" {
  description = "The allocated storage for the RDS instance in GB."
  type        = number
  default     = 20
}

variable "api_key_secret_name" {
  description = "The name of the secret in AWS Secrets Manager for the API key."
  type        = string
  default     = "test/sde_api/key"
}

variable "s3_bucket_name" {
  description = "The name of the S3 bucket for data pipeline assets. Must be globally unique."
  type        = string
  # This should be globally unique, so no default is provided.
  # A user must provide this value in a .tfvars file.
}

variable "airflow_docker_image" {
  description = "The ECR URL for the custom Airflow Docker image."
  type        = string
  # No default, must be provided.
}

variable "acm_certificate_arn" {
  description = "The ARN of the ACM certificate for the ALB's HTTPS listener."
  type        = string
  # No default, must be provided for HTTPS setup.
}