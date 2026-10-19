terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Remote state in a private, versioned, encrypted S3 bucket (S3-native locking).
  # To keep state local instead, delete this block and run `terraform init -migrate-state`.
  backend "s3" {
    bucket       = "hermes-jm-tfstate-296aecc3"
    key          = "hermes-agent/terraform.tfstate"
    region       = "ap-southeast-1"
    encrypt      = true
    use_lockfile = true
  }
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
