output "rds_instance_endpoint" {
  description = "The endpoint hostname of the RDS instance."
  value       = module.rds_postgres.db_instance_endpoint
  sensitive   = false # The endpoint is generally not sensitive, but the password is.
}

output "rds_instance_port" {
  description = "The connection port of the RDS instance."
  value       = module.rds_postgres.db_instance_port
}

output "rds_security_group_id" {
  description = "The ID of the security group attached to the RDS instance."
  value       = module.rds_postgres.db_security_group_id
}

output "s3_bucket_id" {
  description = "The name (ID) of the S3 bucket used for data pipeline assets."
  value       = aws_s3_bucket.data_pipeline_bucket.id
}

output "airflow_webserver_url" {
  description = "The URL of the Airflow webserver, available if an Application Load Balancer (ALB) is enabled."
  value       = module.airflow_on_fargate.webserver_url
}