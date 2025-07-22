/*
Module: ecs_fargate_airflow
Description: Provisions a complete, production-ready Apache Airflow environment on AWS
ECS using the Fargate launch type and the Celery Executor.

This module creates an ECS cluster, task definitions, and services for the Airflow
Webserver, Scheduler, and Workers. It also provisions necessary supporting infrastructure,
including an Application Load Balancer (ALB), an EFS file system for persistent DAGs and
logs, an ElastiCache for Redis cluster as the Celery broker, and all required IAM roles
and security groups.
*/

variable "project_name" {
  description = "A name for the project to prefix resources"
  type        = string
}

variable "vpc_id" {
  description = "The ID of the VPC to deploy Airflow into"
  type        = string
}

variable "private_subnet_ids" {
  description = "List of private subnet IDs for Fargate tasks"
  type        = list(string)
}

variable "public_subnet_ids" {
  description = "List of public subnet IDs (needed for ALB if webserver is public)"
  type        = list(string)
}

variable "etl_task_role_arn" {
  description = "ARN of the IAM role for ETL tasks (used by Airflow workers)"
  type        = string
}

variable "db_instance_endpoint" {
  description = "RDS instance endpoint for Airflow metadata DB"
  type        = string
}

variable "db_instance_port" {
  description = "RDS instance port for Airflow metadata DB"
  type        = number
}

variable "db_security_group_id" {
  description = "Security group ID for the RDS instance (to allow ingress from Airflow SG)"
  type        = string
}

variable "db_name" {
  description = "The name of the Airflow metadata database"
  type        = string
}

variable "db_username" {
  description = "The username for the Airflow metadata database"
  type        = string
}

# Airflow Docker image (must contain Airflow, Python, ETL script, dbt)
variable "airflow_docker_image" {
  description = "Docker image URL for Airflow tasks (e.g., ECR repo URL)"
  type        = string
}

variable "db_password_secret_arn" {
  description = "ARN of the Secrets Manager secret containing the DB master password"
  type        = string
}

variable "api_key_secret_name" {
  description = "The name of the secret in AWS Secrets Manager for the API key."
  type        = string
}

variable "aws_region" {
  description = "The AWS region where the resources are deployed."
  type        = string
}

variable "acm_certificate_arn" {
  description = "ARN of the ACM certificate for the ALB HTTPS listener"
  type        = string
}

variable "airflow_worker_cpu" {
  description = "CPU units for the Airflow worker tasks"
  type        = number
  default     = 1024
}

variable "airflow_webserver_cpu" {
  description = "CPU units for the Airflow webserver task"
  type        = number
  default     = 512
}

variable "airflow_webserver_memory" {
  description = "Memory for the Airflow webserver task"
  type        = number
  default     = 1024
}

variable "airflow_scheduler_cpu" {
  description = "CPU units for the Airflow scheduler task"
  type        = number
  default     = 512
}

variable "airflow_scheduler_memory" {
  description = "Memory for the Airflow scheduler task"
  type        = number
  default     = 1024
}

variable "airflow_worker_memory" {
  description = "Memory for the Airflow worker task"
  type        = number
  default     = 2048
}

variable "airflow_worker_min_count" {
  description = "Minimum number of Airflow worker tasks for auto-scaling"
  type        = number
  default     = 1
}

variable "airflow_worker_max_count" {
  description = "Maximum number of Airflow worker tasks for auto-scaling"
  type        = number
  default     = 4
}

resource "aws_ecs_cluster" "airflow" {
  name = "${var.project_name}-airflow-cluster"

  tags = {
    Name    = "${var.project_name}-airflow-cluster"
    Project = var.project_name
  }
}

resource "aws_security_group" "airflow_tasks" {
  name_prefix = "${var.project_name}-airflow-tasks-"
  description = "Security group for Airflow Fargate tasks"
  vpc_id      = var.vpc_id

  # Allow tasks within the SG to talk to each other (e.g., webserver to scheduler)
  ingress {
    description = "Allow internal SG traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
  }

  # Allow outbound internet access (to API, Secrets Manager, S3)
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Allow ingress from the ALB
  ingress {
    description     = "Allow ALB to connect to webserver"
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.airflow_alb.id]
  }

  tags = { Name = "${var.project_name}-airflow-tasks" }
}

resource "aws_security_group_rule" "airflow_to_rds" {
  type              = "ingress"
  from_port         = var.db_instance_port
  to_port           = var.db_instance_port
  protocol          = "tcp"
  security_group_id = var.db_security_group_id # RDS SG
  source_security_group_id = aws_security_group.airflow_tasks.id # Airflow SG
  description       = "Allow Airflow tasks to connect to RDS"
}

resource "aws_security_group_rule" "airflow_to_redis" {
  type                     = "ingress"
  from_port                = 6379 # Redis port
  to_port                  = 6379
  protocol                 = "tcp"
  security_group_id        = aws_security_group.redis.id
  source_security_group_id = aws_security_group.airflow_tasks.id
  description              = "Allow Airflow tasks to connect to Redis"
}

# This IAM role is assumed by the ECS agent to perform actions on your behalf,
# such as pulling container images from ECR and writing logs to CloudWatch.
resource "aws_iam_role" "airflow_task_execution_role" {
  name = "${var.project_name}-airflow-task-exec-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Action = "sts:AssumeRole",
      Effect = "Allow",
      Principal = {
        Service = "ecs-tasks.amazonaws.com"
      }
    }]
  })
}

# Attaches the AWS-managed policy that grants the necessary permissions for the ECS agent.
resource "aws_iam_role_policy_attachment" "airflow_task_execution_role_policy" {
  role       = aws_iam_role.airflow_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_efs_file_system" "airflow_data" {
  creation_token = "${var.project_name}-airflow-efs"
  performance_mode = "generalPurpose" # Or maxIO for higher throughput needs
  throughput_mode  = "bursting"      # Or provisioned for consistent throughput
  encrypted        = true             # Enable encryption at rest

  # Cost optimization: Move files (especially old logs) to Infrequent Access storage
  lifecycle_policy {
    # Transition files to the EFS Infrequent Access (IA) storage class if they have not been accessed for 30 days.
    transition_to_ia = "AFTER_30_DAYS" # Other options include AFTER_7_DAYS, AFTER_14_DAYS, AFTER_60_DAYS, etc.
  }

  tags = {
    Name    = "${var.project_name}-airflow-efs"
    Project = var.project_name
  }
}

resource "aws_security_group" "efs_access" {
  name_prefix = "${var.project_name}-efs-access-"
  description = "Allow NFS access to EFS from Airflow tasks"
  vpc_id      = var.vpc_id

  ingress {
    description     = "NFS from Airflow Tasks SG"
    from_port       = 2049 # NFS port
    to_port         = 2049
    protocol        = "tcp"
    security_groups = [aws_security_group.airflow_tasks.id] # Allow from Airflow tasks SG
  }

  egress { # Allow all outbound, can be restricted if needed
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-efs-access" }
}

resource "aws_efs_mount_target" "airflow_data" {
  count           = length(var.private_subnet_ids) # Create a mount target in each private subnet
  file_system_id  = aws_efs_file_system.airflow_data.id
  subnet_id       = var.private_subnet_ids[count.index]
  security_groups = [aws_security_group.efs_access.id]
}

resource "aws_cloudwatch_log_group" "airflow" {
  name = "/ecs/airflow/${var.project_name}"
  retention_in_days = 30 # Or your desired retention

  tags = {
    Name = "${var.project_name}-airflow-logs"
  }
}

locals {
  # Define EFS volume configuration once to reuse in task definitions
  efs_volume_configuration = {
    name = "airflow-efs-data"
    efsVolumeConfiguration = {
      fileSystemId = aws_efs_file_system.airflow_data.id
      transitEncryption = "ENABLED" # Recommended
      # rootDirectory = "/" # Optional: specify a subdirectory on EFS
    }
  }
  # Define common mount points for DAGs and Logs
  dags_mount_point = {
    sourceVolume  = local.efs_volume_configuration.name
    containerPath = "/opt/airflow/dags" # Standard Airflow DAGs path
    readOnly      = false # Workers might write logs here if configured, scheduler needs to write .pyc
  }
  logs_mount_point = {
    sourceVolume  = local.efs_volume_configuration.name
    containerPath = "/opt/airflow/logs" # Standard Airflow logs path
    readOnly      = false
  }
  plugins_mount_point = {
    sourceVolume  = local.efs_volume_configuration.name
    containerPath = "/opt/airflow/plugins" # Standard Airflow plugins path
    readOnly      = true # Typically plugins are read-only at runtime
  }
}

locals {
  # Common environment variables for all Airflow components.
  # The full connection strings will need to be constructed by the container's entrypoint
  # using the password from the secret injected below. This is a more secure pattern.
  common_airflow_environment = [
    { name = "AIRFLOW__CORE__EXECUTOR", value = "CeleryExecutor" },
    { name = "AIRFLOW__CELERY__BROKER_URL", value = "redis://${aws_elasticache_cluster.redis.cache_nodes[0].address}:${aws_elasticache_cluster.redis.cache_nodes[0].port}/0" },
    { name = "DB_USER", value = var.db_username },
    { name = "DB_HOST", value = var.db_instance_endpoint },
    { name = "DB_PORT", value = var.db_instance_port },
    { name = "DB_NAME", value = var.db_name },
  ]

  # Securely reference the DB password from Secrets Manager for injection at runtime.
  db_password_secret_config = [{
    name      = "DB_PASSWORD" # The env var name inside the container
    valueFrom = var.db_password_secret_arn
  }]
}

resource "aws_ecs_task_definition" "airflow_webserver" {
  family                   = "${var.project_name}-airflow-webserver"
  cpu                      = var.airflow_webserver_cpu
  memory                   = var.airflow_webserver_memory
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"] 
  execution_role_arn       = aws_iam_role.airflow_task_execution_role.arn
  # The task role grants permissions to the Airflow application itself.
  # Useful for features like the S3/Secrets Manager secrets backend.
  task_role_arn            = var.etl_task_role_arn
  container_definitions    = jsonencode([
    {
      name        = "airflow-webserver"
      image       = var.airflow_docker_image
      command     = ["webserver"]
      portMappings = [{ containerPort = 8080, protocol = "tcp" }]
      environment = local.common_airflow_environment
      secrets     = local.db_password_secret_config
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group" = aws_cloudwatch_log_group.airflow.name
          "awslogs-region" = var.aws_region
          "awslogs-stream-prefix" = "ecs/webserver"
        }
      }
      mountPoints = [
        local.dags_mount_point,
        local.logs_mount_point,
        local.plugins_mount_point
      ]
    }
  ])
  volume {
    name = local.efs_volume_configuration.name
    efs_volume_configuration {
      file_system_id          = aws_efs_file_system.airflow_data.id
      transit_encryption      = "ENABLED"
    }
  }
}

resource "aws_ecs_task_definition" "airflow_scheduler" {
  family                   = "${var.project_name}-airflow-scheduler"
  cpu                      = var.airflow_scheduler_cpu
  memory                   = var.airflow_scheduler_memory
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  execution_role_arn       = aws_iam_role.airflow_task_execution_role.arn 
  # The task role grants permissions to the Airflow application itself.
  # The scheduler needs this to parse DAGs that might interact with AWS services.
  task_role_arn            = var.etl_task_role_arn
  container_definitions    = jsonencode([
    {
      name        = "airflow-scheduler"
      image       = var.airflow_docker_image
      command     = ["scheduler"]
      environment = local.common_airflow_environment
      secrets     = local.db_password_secret_config
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group" = aws_cloudwatch_log_group.airflow.name
          "awslogs-region" = var.aws_region
          "awslogs-stream-prefix" = "ecs/scheduler"
        }
      }
      mountPoints = [
        local.dags_mount_point,
        local.logs_mount_point,
        local.plugins_mount_point
      ]
    }
  ])
  volume {
    name = local.efs_volume_configuration.name
    efs_volume_configuration {
      file_system_id          = aws_efs_file_system.airflow_data.id
      transit_encryption      = "ENABLED"
    }
  }
}

resource "aws_ecs_task_definition" "airflow_worker" {
  family                   = "${var.project_name}-airflow-worker"
  cpu                      = var.airflow_worker_cpu # Adjust based on workload
  memory                   = var.airflow_worker_memory
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  execution_role_arn       = aws_iam_role.airflow_task_execution_role.arn
  task_role_arn            = var.etl_task_role_arn # Worker needs permissions to run ETL tasks
  container_definitions    = jsonencode([
    {
      name        = "airflow-worker"
      image       = var.airflow_docker_image
      command     = ["worker"]
      environment = concat(local.common_airflow_environment, [
        # Pass ETL_ENV_VARS here or via Airflow Variables (e.g., API_KEY_SECRET_NAME, AWS_REGION)
        { name = "API_KEY_SECRET_NAME", value = var.api_key_secret_name }, # Pass directly or via Airflow Variable
        { name = "AWS_REGION", value = var.aws_region }, # Pass directly or via Airflow Variable
      ])
      secrets     = local.db_password_secret_config
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group" = aws_cloudwatch_log_group.airflow.name
          "awslogs-region" = var.aws_region
          "awslogs-stream-prefix" = "ecs/worker"
        }
      }
      mountPoints = [
        local.dags_mount_point,
        local.logs_mount_point,
        local.plugins_mount_point
      ]
    }
  ])
  volume {
    name = local.efs_volume_configuration.name
    efs_volume_configuration {
      file_system_id     = aws_efs_file_system.airflow_data.id
      transit_encryption = "ENABLED"
    }
  }
}

resource "aws_ecs_service" "airflow_webserver" {
  name            = "${var.project_name}-airflow-webserver-service"
  cluster         = aws_ecs_cluster.airflow.id
  task_definition = aws_ecs_task_definition.airflow_webserver.arn
  desired_count   = 1 # Usually 1 webserver
  launch_type     = "FARGATE"
  network_configuration {
    subnets         = var.private_subnet_ids
    security_groups = [aws_security_group.airflow_tasks.id]
    assign_public_ip = false # Keep in private subnets
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.airflow_web.arn
    container_name   = "airflow-webserver"
    container_port   = 8080
  }

  depends_on = [aws_lb_listener.https]
}

resource "aws_ecs_service" "airflow_scheduler" {
  name            = "${var.project_name}-airflow-scheduler-service"
  cluster         = aws_ecs_cluster.airflow.id
  task_definition = aws_ecs_task_definition.airflow_scheduler.arn
  desired_count   = 1 # Usually 1 scheduler
  launch_type     = "FARGATE"
  network_configuration {
    subnets         = var.private_subnet_ids
    security_groups = [aws_security_group.airflow_tasks.id]
    assign_public_ip = false # Keep in private subnets
  }
}

resource "aws_ecs_service" "airflow_worker" {
  name            = "${var.project_name}-airflow-worker-service"
  cluster         = aws_ecs_cluster.airflow.id
  task_definition = aws_ecs_task_definition.airflow_worker.arn
  desired_count   = var.airflow_worker_min_count # Start with the minimum number of workers
  launch_type     = "FARGATE"
  enable_ecs_managed_tags = true

  network_configuration {
    subnets         = var.private_subnet_ids
    security_groups = [aws_security_group.airflow_tasks.id]
    assign_public_ip = false # Keep in private subnets
  }

  # The deployment circuit breaker automatically rolls back failed deployments.
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }
}

resource "aws_appautoscaling_target" "worker_scaling_target" {
  max_capacity       = var.airflow_worker_max_count
  min_capacity       = var.airflow_worker_min_count
  resource_id        = "service/${aws_ecs_cluster.airflow.name}/${aws_ecs_service.airflow_worker.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "worker_scale_cpu" {
  name               = "${var.project_name}-worker-scale-cpu"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.worker_scaling_target.resource_id
  scalable_dimension = aws_appautoscaling_target.worker_scaling_target.scalable_dimension
  service_namespace  = aws_appautoscaling_target.worker_scaling_target.service_namespace

  target_tracking_scaling_policy_configuration {
    target_value       = 75 # Target average CPU utilization at 75%
    scale_in_cooldown  = 300 # Cooldown period in seconds before another scale-in activity can start
    scale_out_cooldown = 60  # Cooldown period in seconds before another scale-out activity can start

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}

resource "aws_appautoscaling_policy" "worker_scale_memory" {
  name               = "${var.project_name}-worker-scale-memory"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.worker_scaling_target.resource_id
  scalable_dimension = aws_appautoscaling_target.worker_scaling_target.scalable_dimension
  service_namespace  = aws_appautoscaling_target.worker_scaling_target.service_namespace

  target_tracking_scaling_policy_configuration {
    target_value       = 75 # Target average Memory utilization at 75%
    scale_in_cooldown  = 300
    scale_out_cooldown = 60

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageMemoryUtilization"
    }
  }
}

resource "aws_security_group" "airflow_alb" {
  name_prefix = "${var.project_name}-alb-sg-"
  description = "Allow HTTP and HTTPS traffic to Airflow ALB"
  vpc_id      = var.vpc_id

  ingress {
    description = "HTTP from anywhere for redirection"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS from anywhere"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_lb" "airflow_web" {
  name               = "${var.project_name}-airflow-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.airflow_alb.id]
  subnets            = var.public_subnet_ids
}

resource "aws_lb_target_group" "airflow_web" {
  name        = "${var.project_name}-airflow-web-tg"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    path                = "/health"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.airflow_web.arn
  port              = "443"
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-2016-08"
  certificate_arn   = var.acm_certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.airflow_web.arn
  }
}

resource "aws_lb_listener" "http_redirect" {
  load_balancer_arn = aws_lb.airflow_web.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

resource "aws_elasticache_subnet_group" "redis" {
  name       = "${var.project_name}-redis-subnet-group"
  subnet_ids = var.private_subnet_ids
}

resource "aws_security_group" "redis" {
  name_prefix = "${var.project_name}-redis-sg-"
  description = "Allow Redis traffic from Airflow tasks"
  vpc_id      = var.vpc_id
}

resource "aws_elasticache_cluster" "redis" {
  cluster_id           = "${var.project_name}-redis-cluster"
  engine               = "redis"
  node_type            = "cache.t4g.small" # Cost-effective choice for dev/test
  num_cache_nodes      = 1
  parameter_group_name = "default.redis7"
  engine_version       = "7.0"
  port                 = 6379
  subnet_group_name    = aws_elasticache_subnet_group.redis.name
  security_group_ids   = [aws_security_group.redis.id]
}

# The data source to retrieve the secret is no longer needed, as we are using the `secrets`
# block in the container definition, which is the more secure, modern approach.
# data "aws_secretsmanager_secret_version" "db_password" {
#  secret_id = var.db_password_secret_arn
# }

output "efs_file_system_id" {
  description = "The ID of the EFS file system used for persistent DAGs and logs."
  value       = aws_efs_file_system.airflow_data.id
}
output "webserver_url" {
  description = "The public URL of the Airflow webserver, served by the Application Load Balancer."
  value       = "https://${aws_lb.airflow_web.dns_name}"
}