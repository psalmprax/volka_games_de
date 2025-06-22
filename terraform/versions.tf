/*
This file defines the required Terraform version and the versions of the providers
used in this project. Pinning versions is a best practice that ensures consistent
and predictable behavior across different environments and team members. It prevents
unexpected changes or breakages that can occur when a new major version of a
provider or Terraform itself is released.
*/

terraform {
  # Specifies the minimum version of the Terraform CLI required to apply this configuration.
  # This ensures that all team members are using a compatible version of Terraform.
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      # The tilde-greater-than (~>) operator allows for patch and minor updates within a
      # specific major version. For example, "~> 5.0" will match any version from 5.0.0
      # up to, but not including, 6.0.0. This provides a balance between receiving bug
      # fixes and avoiding breaking changes from a new major version.
      version = "~> 5.0"
    }
  }
}

