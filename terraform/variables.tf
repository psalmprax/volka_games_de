/*
Root Variables
Description: This file defines the input variables for the root Terraform configuration.
These variables are used to configure the various modules (VPC, RDS, IAM, ECS) that
make up the data pipeline infrastructure.

Values for these variables can be provided via a .tfvars file or command-line flags.
*/

variable "aws_region" {
  description = "The AWS region where all infrastructure resources will be deployed."
  type        = string
  default     = "eu-central-1"
}

variable "project_name" {
  description = "A unique name for the project, used as a prefix for all created resources to ensure clear identification and prevent naming conflicts."
  type        = string
  default     = "volka-de-pipeline"
}

variable "vpc_cidr" {
  description = "The root CIDR block for the project's VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "db_name" {
  description = "The name for the RDS database that will be used as the Airflow metadata store."
  type        = string
  default     = "airflow_db"
}

variable "db_username" {
  description = "The master username for the RDS database."
  type        = string
  default     = "airflow_user"
}

variable "db_instance_class" {
  description = "The instance class for the RDS PostgreSQL instance (e.g., db.t4g.small)."
  type        = string
  default     = "db.t4g.small"
}

variable "db_allocated_storage" {
  description = "The initial allocated storage for the RDS instance in gigabytes."
  type        = number
  default     = 20
}

variable "api_key_secret_name" {
  description = "The name (not ARN) of the secret in AWS Secrets Manager containing the external API key."
  type        = string
  default     = "test/sde_api/key"
}

variable "s3_bucket_name" {
  description = "The globally unique name for the S3 bucket that will store data pipeline assets. A value must be provided as there is no default."
  type        = string
}

variable "airflow_docker_image" {
  description = "The full ECR repository URL for the custom Airflow Docker image (e.g., 123456789012.dkr.ecr.region.amazonaws.com/my-airflow:latest). A value must be provided."
  type        = string
}

variable "acm_certificate_arn" {
  description = "The ARN of a pre-existing ACM certificate in the same region. This is required to enable HTTPS on the Application Load Balancer for the Airflow webserver. A value must be provided."
  type        = string
}