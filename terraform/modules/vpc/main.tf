/*
Module: vpc
Description: Provisions a standard AWS VPC with public and private subnets across multiple
Availability Zones. It includes an Internet Gateway for public subnets and NAT Gateways
for private subnets to allow outbound internet access.
*/

variable "project_name" {
  description = "The name of the project, used to prefix resource names for identification."
  type        = string
}

variable "vpc_cidr" {
  description = "The CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "A list of CIDR blocks for the public subnets. The number of subnets determines the number of Availability Zones used."
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_subnet_cidrs" {
  description = "A list of CIDR blocks for the private subnets. Should have the same number of elements as public_subnet_cidrs."
  type        = list(string)
  default     = ["10.0.101.0/24", "10.0.102.0/24"]
}

# Retrieves the list of available Availability Zones in the current AWS region.
# This allows for dynamic and resilient placement of subnets.
data "aws_availability_zones" "available" {
  state = "available"
}

# The main Virtual Private Cloud (VPC) resource.
resource "aws_vpc" "main" {
  cidr_block = var.vpc_cidr
  # DNS settings are enabled to allow AWS services (like RDS, EC2) within the VPC
  # to resolve public and private DNS hostnames.
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name    = "${var.project_name}-vpc"
    Project = var.project_name
  }
}

# The Internet Gateway (IGW) allows communication between the VPC and the internet.
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-igw"
  }
}

# Creates a public subnet in each specified Availability Zone.
# These subnets are intended for public-facing resources like load balancers.
resource "aws_subnet" "public" {
  count             = length(var.public_subnet_cidrs)
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.public_subnet_cidrs[count.index]
  availability_zone = data.aws_availability_zones.available.names[count.index]
  # Instances launched in this subnet will receive a public IP address by default.
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.project_name}-public-subnet-${count.index + 1}"
  }
}

# Creates a private subnet in each specified Availability Zone.
# These subnets are for backend resources that should not be directly accessible from the internet.
resource "aws_subnet" "private" {
  count             = length(var.private_subnet_cidrs)
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = {
    Name = "${var.project_name}-private-subnet-${count.index + 1}"
  }
}

# --- NAT Gateway and Routing for Private Subnets ---
# Provisions an Elastic IP and a NAT Gateway in each public subnet for high availability.
resource "aws_eip" "nat_gateway" {
  count = length(var.public_subnet_cidrs)

  tags = {
    Name = "${var.project_name}-nat-eip-${count.index + 1}"
  }
}

resource "aws_nat_gateway" "main" {
  count         = length(var.public_subnet_cidrs)
  allocation_id = aws_eip.nat_gateway[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = {
    Name = "${var.project_name}-nat-gateway-${count.index + 1}"
  }

  # Explicitly depend on the Internet Gateway to ensure the VPC is connected to the
  # internet before creating the NAT Gateway.
  depends_on = [aws_internet_gateway.main]
}

# Creates a dedicated route table for each private subnet.
resource "aws_route_table" "private" {
  count  = length(var.private_subnet_cidrs)
  vpc_id = aws_vpc.main.id

  route {
    # Routes all outbound internet traffic (0.0.0.0/0) to the NAT Gateway.
    # This routes traffic to the NAT Gateway in the same AZ, which is crucial for
    # performance and to avoid cross-AZ data transfer costs.
    cidr_block = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main[count.index].id
  }

  tags = {
    Name = "${var.project_name}-private-rt-${count.index + 1}"
  }
}

# Associates each private subnet with its corresponding private route table.
resource "aws_route_table_association" "private" {
  count          = length(var.private_subnet_cidrs)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# --- Module Outputs ---

output "vpc_id" {
  description = "The ID of the created VPC."
  value       = aws_vpc.main.id
}
output "private_subnet_ids" {
  description = "A list of IDs for the private subnets."
  value       = aws_subnet.private[*].id
}
output "public_subnet_ids" {
  description = "A list of IDs for the public subnets."
  value       = aws_subnet.public[*].id
}
output "private_route_table_ids" {
  description = "A list of IDs for the private route tables."
  value       = aws_route_table.private[*].id
}
output "public_subnet_cidrs" {
  description = "A list of CIDR blocks for the public subnets. Useful for security group rules."
  value       = aws_subnet.public[*].cidr_block
}
output "private_subnet_cidrs" {
  description = "A list of CIDR blocks for the private subnets. Useful for security group rules."
  value       = aws_subnet.private[*].cidr_block
}