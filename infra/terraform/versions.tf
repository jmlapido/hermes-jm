terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Optional: remote state. Uncomment and fill in to keep state in S3.
  # backend "s3" {
  #   bucket       = "my-tfstate-bucket"
  #   key          = "hermes-agent/terraform.tfstate"
  #   region       = "ap-southeast-1"
  #   use_lockfile = true
  # }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "hermes-agent"
      ManagedBy = "terraform"
    }
  }
}
