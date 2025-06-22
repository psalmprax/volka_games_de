# Example Outputs

output "rds_instance_endpoint" {
  description = "The endpoint of the RDS instance"
  value       = module.rds_postgres.db_instance_endpoint # This will be the actual value from the module
  sensitive   = false # Endpoint is generally not sensitive, but password is
}

output "rds_instance_port" {
  description = "The port of the RDS instance"
  value       = module.rds_postgres.db_instance_port # This will be the actual value from the module
}

output "rds_security_group_id" {
  description = "The ID of the security group for the RDS instance"
  value       = module.rds_postgres.db_security_group_id
}

output "s3_bucket_id" {
  description = "The ID (name) of the S3 data pipeline bucket"
  value       = aws_s3_bucket.data_pipeline_bucket.id
}

# # Add other outputs as needed, e.g., Airflow Webserver URL if using ALB
output "airflow_webserver_url" {
  description = "The URL of the Airflow webserver (if using ALB)"
  value       = module.airflow_on_fargate.webserver_url # Assuming module outputs this
}