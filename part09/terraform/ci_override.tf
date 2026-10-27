# CI only: plan without an AWS account. Terraform merges *_override.tf files into main.tf:
# the local backend replaces S3, and the provider gets mock credentials and skips its checks.
terraform {
  backend "local" {}
}

provider "aws" {
  access_key                  = "mock"
  secret_key                  = "mock"
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
}
