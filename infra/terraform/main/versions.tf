terraform {
  required_version = ">= 1.10"
  required_providers {
    aws   = { source = "hashicorp/aws", version = "~> 6.0" }
    local = { source = "hashicorp/local", version = "~> 2.5" }
  }

  backend "s3" {
    bucket       = "retail-store-tfstate-078525504844" # ← output state_bucket
    key          = "main/terraform.tfstate"
    region       = "ap-southeast-1"
    encrypt      = true
    use_lockfile = true # khoá state bằng file .tflock trên S3, không cần DynamoDB
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = { Project = "retail-store", ManagedBy = "terraform" }
  }
}
