terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0" # Example: Allow versions 5.x, but not 6.x
    }
  }
  required_version = ">= 1.5" # Specify the minimum Terraform version
}