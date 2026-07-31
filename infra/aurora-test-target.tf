terraform {
  required_version = ">= 1.3"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

# Minimal, standalone Aurora cluster for the harness-poc-vpc-connectivity-test
# pipeline. Deliberately does NOT use the terraform-twilio-aws-aurora module -
# that module unconditionally wires up Datadog + PagerDuty (no opt-out) and
# requires a live datadog_api_key/pagerduty_service_name, neither of which
# exist for this disposable POC target. Lives in the same VPC/private subnets
# as the harness-poc EKS cluster so the delegate can reach it directly.

locals {
  vpc_id             = "vpc-03e74700845a3fd3e"
  private_subnet_ids = ["subnet-0a53a43b9278b1b7b", "subnet-0e03fe41c740515df"]
  cluster_name       = "harness-poc-connectivity-test"
}

data "aws_vpc" "harness_poc" {
  id = local.vpc_id
}

resource "aws_db_subnet_group" "connectivity_test" {
  name       = local.cluster_name
  subnet_ids = local.private_subnet_ids

  tags = {
    env     = "poc"
    project = "harness-poc-vpc-connectivity-test"
    owner   = "eleepierce"
  }
}

resource "aws_security_group" "connectivity_test_db" {
  name        = "${local.cluster_name}-db"
  description = "Allow MySQL access from within the harness-poc VPC for the delegate connectivity test"
  vpc_id      = local.vpc_id

  ingress {
    description = "MySQL from within the harness-poc VPC"
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.harness_poc.cidr_block]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    env     = "poc"
    project = "harness-poc-vpc-connectivity-test"
    owner   = "eleepierce"
  }
}

resource "aws_rds_cluster" "connectivity_test" {
  cluster_identifier           = local.cluster_name
  engine                       = "aurora-mysql"
  engine_version               = "8.0.mysql_aurora.3.10.3"
  database_name                = "connectivitytest"
  master_username              = "admin"
  manage_master_user_password  = true
  db_subnet_group_name         = aws_db_subnet_group.connectivity_test.name
  vpc_security_group_ids       = [aws_security_group.connectivity_test_db.id]
  storage_encrypted            = true
  skip_final_snapshot          = true
  apply_immediately            = true

  tags = {
    env     = "poc"
    project = "harness-poc-vpc-connectivity-test"
    owner   = "eleepierce"
  }
}

resource "aws_rds_cluster_instance" "connectivity_test" {
  identifier         = "${local.cluster_name}-0"
  cluster_identifier = aws_rds_cluster.connectivity_test.id
  instance_class     = "db.t4g.medium"
  engine             = aws_rds_cluster.connectivity_test.engine
  engine_version     = aws_rds_cluster.connectivity_test.engine_version

  tags = {
    env     = "poc"
    project = "harness-poc-vpc-connectivity-test"
    owner   = "eleepierce"
  }
}

output "cluster_endpoint" {
  value = aws_rds_cluster.connectivity_test.endpoint
}

output "cluster_port" {
  value = aws_rds_cluster.connectivity_test.port
}

output "master_user_secret_arn" {
  value = aws_rds_cluster.connectivity_test.master_user_secret[0].secret_arn
}
