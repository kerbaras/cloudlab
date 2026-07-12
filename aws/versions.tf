# Terraform record of the cloudlab AWS footprint (account 203447569320,
# profile "personal"). Everything here was created imperatively during the
# rebuild and imported via the blocks in imports.tf.
#
# Bootstrap (one-time, already done): the state bucket itself —
#   aws s3api create-bucket --bucket cloudlab-tfstate-203447569320 --region us-east-1
#   aws s3api put-bucket-versioning --versioning-configuration Status=Enabled ...
#
# Run with (terraform's SDK can't read `aws login` root sessions directly,
# same as sops):
#   eval "$(aws configure export-credentials --profile personal --format env)"
#   terraform -chdir=aws plan
terraform {
  required_version = ">= 1.10"

  backend "s3" {
    bucket       = "cloudlab-tfstate-203447569320"
    key          = "cloudlab.tfstate"
    region       = "us-east-1"
    use_lockfile = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}
