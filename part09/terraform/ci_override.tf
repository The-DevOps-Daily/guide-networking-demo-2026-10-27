# CI only: plan without an AWS account. Terraform merges *_override.tf files into main.tf.
provider "aws" {
  access_key                  = "mock"
  secret_key                  = "mock"
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
}
