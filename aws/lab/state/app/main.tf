# Workload whose state lives in the bootstrap backend. Cheap resources only: the tests are
# about the state, not the cloud objects.
terraform {
  required_version = "~> 1.5"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.58" }
  }
  backend "s3" {}
}

variable "floci_endpoint" {
  type    = string
  default = "http://floci-lab:4566"
}

variable "queues" {
  type    = number
  default = 3
}

provider "aws" {
  region                      = "us-east-1"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_region_validation      = true
  endpoints {
    sqs = var.floci_endpoint
    ssm = var.floci_endpoint
    sts = var.floci_endpoint
  }
}

resource "aws_sqs_queue" "work" {
  count = var.queues
  name  = "state-lab-work-${count.index}"
}

resource "aws_ssm_parameter" "config" {
  name  = "/state-lab/config"
  type  = "String"
  value = jsonencode({ queues = aws_sqs_queue.work[*].name })
}
