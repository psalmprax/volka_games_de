# terraform/modules/iam/main.tf
# This would define IAM roles and policies for ETL tasks (Lambda/Fargate), Airflow, etc.

variable "project_name" {}
variable "api_key_secret_arn" {}
variable "db_password_secret_arn" {}
variable "s3_bucket_arn" {}

# Example: Role for ETL Fargate tasks / Lambda functions
resource "aws_iam_role" "etl_task_role" {
  name = "${var.project_name}-etl-task-role" # This role is used by Airflow workers to run ETL logic
  assume_role_policy = jsonencode({
    Version   = "2012-10-17",
    Statement = [
      {
        Action    = "sts:AssumeRole",
        Effect    = "Allow",
        Principal = { Service = "ecs-tasks.amazonaws.com" }, # Or "lambda.amazonaws.com"
      },
    ],
  })
}

resource "aws_iam_policy" "etl_task_policy" {
  name        = "${var.project_name}-etl-task-policy"
  description = "Policy for Volka ETL tasks to access Secrets Manager, S3, and CloudWatch Logs"
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect   = "Allow",
        Action   = "secretsmanager:GetSecretValue",
        # Allow access to both the API key and the RDS password secrets
        Resource = [var.api_key_secret_arn, var.db_password_secret_arn]
      },
      {
        Effect = "Allow",
        Action = [
          "s3:GetObject",
          "s3:PutObject"
        ],
        # Allow access to objects within the specified bucket
        Resource = "${var.s3_bucket_arn}/*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "etl_task_policy_attach" {
  role       = aws_iam_role.etl_task_role.name
  policy_arn = aws_iam_policy.etl_task_policy.arn
}

output "etl_task_role_arn" { value = aws_iam_role.etl_task_role.arn }

# Add other roles/policies here, e.g., for Airflow Task Execution Role (if not using AWS managed policy)