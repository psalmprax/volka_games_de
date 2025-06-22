/*
Module: iam
Description: Provisions IAM roles and policies required for application services,
such as ETL tasks running on AWS Fargate or Lambda.
*/

variable "project_name" {
  description = "The name of the project, used to prefix resource names for identification."
  type        = string
}
variable "api_key_secret_arn" {
  description = "The ARN of the AWS Secrets Manager secret containing the external API key."
  type        = string
}
variable "db_password_secret_arn" {
  description = "The ARN of the AWS Secrets Manager secret containing the database master password."
  type        = string
}
variable "s3_bucket_arn" {
  description = "The ARN of the S3 bucket used for data storage and processing."
  type        = string
}

# This IAM Role is intended to be assumed by AWS services like ECS Tasks or Lambda
# functions that perform ETL (Extract, Transform, Load) operations.
resource "aws_iam_role" "etl_task_role" {
  name = "${var.project_name}-etl-task-role"

  # The assume role policy defines which principals (e.g., AWS services) are
  # allowed to assume this role. Here, we allow ECS tasks to assume it.
  assume_role_policy = jsonencode({
    Version   = "2012-10-17",
    Statement = [
      {
        Action    = "sts:AssumeRole",
        Effect    = "Allow",
        Principal = { Service = "ecs-tasks.amazonaws.com" }, # Change to "lambda.amazonaws.com" for Lambda functions
      },
    ],
  })
}

resource "aws_iam_policy" "etl_task_policy" {
  name        = "${var.project_name}-etl-task-policy"
  description = "Grants ETL tasks permissions for Secrets Manager, S3, and CloudWatch Logs."
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        # Allows the task to retrieve the database password and API keys from Secrets Manager.
        Effect   = "Allow",
        Action   = "secretsmanager:GetSecretValue",
        Resource = [var.api_key_secret_arn, var.db_password_secret_arn]
      },
      {
        # Allows the task to read and write objects in the specified S3 bucket.
        Effect = "Allow",
        Action = [
          "s3:GetObject",
          "s3:PutObject"
        ],
        Resource = "${var.s3_bucket_arn}/*"
      },
      {
        # Allows the task to create log groups and streams, and to write log events.
        # This is essential for logging and debugging.
        Effect = "Allow",
        Action = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"],
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "etl_task_policy_attach" {
  role       = aws_iam_role.etl_task_role.name
  policy_arn = aws_iam_policy.etl_task_policy.arn
}

output "etl_task_role_arn" {
  description = "The ARN of the IAM role for ETL tasks."
  value       = aws_iam_role.etl_task_role.arn
}