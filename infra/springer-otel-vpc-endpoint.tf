# VPC Interface Endpoint connecting the harness-poc cluster's VPC (an isolated CND
# sandbox account, not OTK/realm) to Springer's regional OTEL gateway, per
# observability:springer-onboarding's isolated-account path. Testing whether a
# hand-installed OTel Collector DaemonSet can capture stdout logs from short-lived,
# run-to-completion Harness CD pods and ship them to ClickHouse - a previously
# untested gap (see README caveats).
#
# dev (us-east-1) regional gateway per the onboarding reference:
#   otelgw-gp0.us-east-1.dev.platform.twilioinfra.com
#   PrivateLink service: com.amazonaws.vpce.us-east-1.vpce-svc-069b9766e20a56035

resource "aws_security_group" "springer_otel_endpoint" {
  name        = "harness-poc-springer-otel-endpoint"
  description = "Allow the harness-poc VPC to reach the Springer OTEL gateway PrivateLink endpoint on 443"
  vpc_id      = local.vpc_id

  ingress {
    description = "HTTPS/gRPC (443) from within the harness-poc VPC"
    from_port   = 443
    to_port     = 443
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
    project = "harness-poc-springer-otel-test"
    owner   = "eleepierce"
  }
}

resource "aws_vpc_endpoint" "springer_otel_gateway_dev" {
  vpc_id              = local.vpc_id
  service_name        = "com.amazonaws.vpce.us-east-1.vpce-svc-069b9766e20a56035"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = local.private_subnet_ids
  security_group_ids  = [aws_security_group.springer_otel_endpoint.id]
  private_dns_enabled = true

  tags = {
    Name    = "harness-poc-springer-otel-gateway-dev"
    env     = "poc"
    project = "harness-poc-springer-otel-test"
    owner   = "eleepierce"
  }
}

output "springer_otel_endpoint_state" {
  value = aws_vpc_endpoint.springer_otel_gateway_dev.state
}

output "springer_otel_endpoint_dns" {
  value = aws_vpc_endpoint.springer_otel_gateway_dev.dns_entry
}
