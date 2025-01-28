---
layout: single
title: Creating Custom VPC Endpoints with AWS PrivateLink
date: 2025-01-28
---

Story Time: So you're sitting there one day, feet up, lazily watching the monitoring dashboard for the service you've
just launched. The boss barges in, "No one wants to buy our service unless they can get it directly in their VPC." Piss
on it. You put your feet down, sit up straight, and start working on setting up
[AWS PrivateLink.](https://aws.amazon.com/privatelink/)

## What is PrivateLink?

> AWS PrivateLink is a networking service that enables you to securely expose your applications or services to other
> VPCs or on-premises networks, without requiring them to traverse the public internet or use VPN connections. With
> PrivateLink, you can create private endpoints in a consumer VPC that connect directly to services in a service
> provider VPC, using private IP addresses. This allows you to keep all traffic between the consumer and provider within
> the AWS network, improving security and reducing latency.
>
> <cite>Claude 3 Opus</cite>

## OK, But Why Do We Want It?

There are several reasons to make your service available via PrivateLink such as:

- Security: By keeping traffic within the AWS network and avoiding the public internet, you reduce the risk of data
  breaches or unauthorized access to your service. Consumers can access your service without needing to open up their
  firewall or whitelist your public IPs.
- Simplified Networking: PrivateLink eliminates the need for the likes of VPNs or VPC Peering. Consumers can easily
  create an endpoint in their VPC and start using your service, without any additional setup.
- Improved Performance: Because traffic stays within the AWS network, PrivateLink connections offer lower latency and
  more consistent performance compared to connections over the public internet.

## Game Plan

This is what we're going to build.

![VPC Diagram](/assets/posts/creating-vpc-endpoints-with-privatelink/vpc_diagram.png)

We create a VPC Endpoint Service that users can then create Endpoints from in their own VPCs. The Endpoint Service
points to a Network Load Balancer. We point this NLB to an Application Load Balancer that handles our SSL encryption.
From there, the ALB forwards the request to an EC2 instance running our application.

Using this we can create a VPC Endpoint in our consumer VPC. The EC2 instance in the consumer VPC can access the service
running on the app servers running in the service VPC via the endpoint without needin to go out over the internet.

## Base Terraform

The first thing we're going to need is some base Terraform configuration.

```terraform
terraform {
  required_version = "~> 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.39"
    }

    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}
```

We'll need the AWS provider, and because this is only a demo and we're too lazy to get a signed certificate, we'll make
use of the TLS provider.

```terraform
data "aws_availability_zones" "available" {
  state = "available"
}
```

We want a list of AZs in our region for later use.

## Creating the Service

Our service is going to be made up of an EC2 instance behind an Application Load Balancer. We also need a Network Load
Balancer for the VPC Endpoint interface.

#### Network

The service sits in its own VPC. We're going to create a subnet for each AZ.

```terraform
resource "aws_vpc" "service" {
  cidr_block = "10.0.0.0/16"
}

resource "aws_subnet" "service" {
  count = length(data.aws_availability_zones.available.names)

  vpc_id                  = aws_vpc.service.id
  cidr_block              = cidrsubnet(aws_vpc.service.cidr_block, 4, count.index)
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true
}
```

We also want a Internet Gateway

```terraform
resource "aws_internet_gateway" "service" {
  vpc_id = aws_vpc.service.id
}

resource "aws_route_table" "service" {
  vpc_id = aws_vpc.service.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.service.id
  }
}

resource "aws_route_table_association" "service" {
  count = length(aws_subnet.service)

  subnet_id      = aws_subnet.service[count.index].id
  route_table_id = aws_route_table.service.id
}
```

We're going to use a Security Group in multiple places. It needs HTTP/S from inside the VPC, and access out to the
intenet so we can install some software on the EC2 instance running our service.

```terraform
resource "aws_security_group" "service" {
  name   = "service"
  vpc_id = aws_vpc.service.id
}

resource "aws_vpc_security_group_ingress_rule" "service_https" {
  security_group_id = aws_security_group.service.id

  description = "HTTPS from Service VPC"
  cidr_ipv4   = aws_vpc.service.cidr_block
  from_port   = 443
  to_port     = 443
  ip_protocol = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "service_http" {
  security_group_id = aws_security_group.service.id

  description = "HTTP from Service VPC"
  cidr_ipv4   = aws_vpc.service.cidr_block
  from_port   = 80
  to_port     = 80
  ip_protocol = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "service_all" {
  security_group_id = aws_security_group.service.id

  description = "Allow all egress"
  cidr_ipv4   = "0.0.0.0/0"
  ip_protocol = "-1"
}
```

#### Service Compute

Speaking of an EC2 instance...

```terraform
data "aws_ami" "amazon_linux_2023" {
  owners      = ["amazon"]
  most_recent = true

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_instance" "service" {
  ami                    = data.aws_ami.amazon_linux_2023.id
  instance_type          = "t3.nano"
  subnet_id              = aws_subnet.service[0].id
  vpc_security_group_ids = [aws_security_group.service.id]
  user_data              = file("${path.module}/userdata.sh")

  key_name = var.key_name

  tags = {
    Name = "PrivateLink Demo Service"
  }
}
```

The userdata for the instance will simply install and start Nginx.

```bash
#!/bin/sh

sudo yum install -y nginx.x86_64
sudo systemctl start nginx
```

#### Application Load Balancer

With our instance running, we can create an Application Load Balancer to route traffic to it.

```terraform
resource "aws_lb" "service_alb" {
  name               = "service-alb"
  internal           = true
  load_balancer_type = "application"
  security_groups    = [aws_security_group.service.id]
  subnets            = aws_subnet.service[*].id
}
```

We need to create a Target Group containing our EC2 instance.

```terraform
resource "aws_lb_target_group" "service_alb" {
  name     = "service"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.service.id
}

resource "aws_lb_target_group_attachment" "service_alb" {
  target_group_arn = aws_lb_target_group.service_alb.arn
  target_id        = aws_instance.service.id
  port             = 80
}
```

The Listener for the ABL needs a certificate if we want to use HTTPS. We're going to use the TLS Terraform provider for
this, but generatlly you'd want a cetificate signed by a trusted CA.

```terraform
resource "tls_private_key" "service" {
  algorithm = "RSA"
}

resource "tls_self_signed_cert" "service" {
  private_key_pem = tls_private_key.service.private_key_pem

  subject {
    common_name  = aws_lb.service_alb.dns_name
    organization = "ACME Demos"
  }

  validity_period_hours = 72 # 3 days

  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth",
  ]
}

resource "aws_acm_certificate" "service" {
  private_key      = tls_private_key.service.private_key_pem
  certificate_body = tls_self_signed_cert.service.cert_pem
}
```

Finally we can add our listener to the Load Balancer.

```terraform
resource "aws_lb_listener" "service_alb" {
  load_balancer_arn = aws_lb.service_alb.arn
  port              = "443"
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-2016-08"
  certificate_arn   = aws_acm_certificate.service.arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.service_alb.arn
  }
}
```

#### Network Load Balancer

Now that we have our Application Load Balancer set up and pointing to the EC2 instace, we can put the Network Load
Balancer in front of it.

```terraform
resource "aws_lb" "service_nlb" {
  name                             = "service-nlb"
  load_balancer_type               = "network"
  enable_cross_zone_load_balancing = false
  internal                         = true
  subnets                          = aws_subnet.service[*].id
}
```

The Load Balancer needs to target the ALB.

```terraform
resource "aws_lb_target_group" "service_nlb" {
  name        = "service-nlb"
  port        = "443"
  protocol    = "TCP"
  target_type = "alb"
  vpc_id      = aws_vpc.service.id

  health_check {
    matcher  = "200"
    path     = "/"
    port     = "443"
    protocol = "HTTPS"
  }
}

resource "aws_lb_target_group_attachment" "service_nlb" {
  port             = aws_lb_listener.service_nlb.port
  target_group_arn = aws_lb_target_group.service_nlb.arn
  target_id        = aws_lb_listener.service_alb.load_balancer_arn
}
```

And connecting the listener to the LB.

```terraform
resource "aws_lb_listener" "service_nlb" {
  load_balancer_arn = aws_lb.service_nlb.arn
  port              = 443
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.service_nlb.arn
  }
}
```

#### Endpoint Service

The last thing to do is to create the VPC Endpoint Service

```terraform
resource "aws_vpc_endpoint_service" "service" {
  acceptance_required        = false
  network_load_balancer_arns = [aws_lb.service_nlb.arn]
}
```

And share it with our target account. This is the current account for now but can be changed as needed.

```terraform
data "aws_caller_identity" "current" {}

resource "aws_vpc_endpoint_service_allowed_principal" "allowed_aws_accounts" {
  vpc_endpoint_service_id = aws_vpc_endpoint_service.service.id
  principal_arn           = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
}
```

## Consuming the Service

With the service created we can move on to standing up an EC2 instance to consume it.

#### Network

First thing we're going to want to do is create a network. This is essentially the same as the Service VPC.

```terraform
resource "aws_vpc" "consumer" {
  cidr_block = "10.0.0.0/16"
}

resource "aws_subnet" "consumer" {
  count = length(data.aws_availability_zones.available.names)

  vpc_id                  = aws_vpc.consumer.id
  cidr_block              = cidrsubnet(aws_vpc.service.cidr_block, 4, count.index)
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true
}

resource "aws_internet_gateway" "consumer" {
  vpc_id = aws_vpc.consumer.id
}

resource "aws_route_table" "consumer" {
  vpc_id = aws_vpc.consumer.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.consumer.id
  }
}

resource "aws_route_table_association" "consumer" {
  count = length(aws_subnet.consumer)

  subnet_id      = aws_subnet.consumer[count.index].id
  route_table_id = aws_route_table.consumer.id
}
```

#### Consumer Compute

We need an EC2 instance we can log into. We'll take the name of a key as a variable.

```terraform
variable "key_name" {
  description = "Name of the Key Pair to use for the EC2 instances"
  type        = string
}

resource "aws_instance" "consumer" {
  ami                    = data.aws_ami.amazon_linux_2023.id
  instance_type          = "t3.nano"
  subnet_id              = aws_subnet.consumer[0].id
  vpc_security_group_ids = [aws_security_group.consumer.id]

  key_name = var.key_name

  tags = {
    Name = "PrivateLink Demo Consumer"
  }
}

resource "aws_security_group" "consumer" {
  name   = "consumer"
  vpc_id = aws_vpc.consumer.id
}

resource "aws_vpc_security_group_ingress_rule" "consumer_ssh" {
  security_group_id = aws_security_group.consumer.id

  description = "SSH from the internet"
  cidr_ipv4   = "0.0.0.0/0"
  from_port   = 22
  to_port     = 22
  ip_protocol = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "consumer_all" {
  security_group_id = aws_security_group.consumer.id

  description = "Allow all egress"
  cidr_ipv4   = "0.0.0.0/0"
  ip_protocol = "-1"
}

output "consumer_public_ip" {
  description = "Public IP address of the Consumer instance"
  value       = aws_instance.consumer.public_ip
}
```

#### PrivateLink

Our VPC Endpoint is going to need a Security Group that allows ingress from the VPC.

```terraform
resource "aws_security_group" "consumer_privatelink" {
  name   = "consumer_privatelink"
  vpc_id = aws_vpc.consumer.id
}

resource "aws_vpc_security_group_ingress_rule" "consumer_privatelink_https" {
  security_group_id = aws_security_group.consumer_privatelink.id

  description = "HTTPS from Consumer VPC"
  cidr_ipv4   = aws_vpc.consumer.cidr_block
  from_port   = 443
  to_port     = 443
  ip_protocol = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "consumer_privatelink_all" {
  security_group_id = aws_security_group.consumer_privatelink.id

  description = "Allow all outbound"
  cidr_ipv4   = "0.0.0.0/0"
  ip_protocol = "-1"
}
```

And we can finally create the VPC Endpoint.

```terraform
resource "aws_vpc_endpoint" "consumer_privatelink" {
  service_name       = aws_vpc_endpoint_service.service.service_name
  security_group_ids = [aws_security_group.consumer_privatelink.id]
  subnet_ids         = aws_subnet.consumer[*].id
  vpc_endpoint_type  = "Interface"
  vpc_id             = aws_vpc.consumer.id
}

output "consumer_endpoint_dns_names" {
  description = "Dmoain names of the Consumer VPC Endpoint"
  value       = [for dns_entry in aws_vpc_endpoint.consumer_privatelink.dns_entry : "https://${dns_entry.dns_name}"]
}
```

## Testing

With all this deployed you should be good to test it out. Connect to the Consumer EC2 instance using the public IP
address in the Terraform outputs. Once connected, cURL the first VPC Endpoint URL in the `consumer_endpoint_dns_names`
output variable. You should see the standard Nginx landing page.

## Conclusion

In this post, we walked through the process of creating VPC endpoints with AWS PrivateLink using Terraform. We started
by setting up a service providerEC2 instance inside a VPC behind an Application Load Balancer and Network Load Balancer.
We then created a VPC Endpoint Service and shared it with a consumer VPC, allowing the consumer to securely access the
service over the AWS network.

By using PrivateLink, we were able to improve the security, performance, and operational efficiency of our service.
Consumers can now access the service without exposing it to the public internet or configuring complex network settings.
Traffic stays within the AWS network, reducing latency and increasing compliance.

One important aspect of the setup is the allowed principal configuration, which controls which AWS accounts or IAM users
can create endpoints to connect to the service. Here we've manually specified the allowed principal based on the current
AWS account ID. However, in a real-world scenario, you may want to automate this depending on how new consumers are to
be added to the system.

AWS PrivateLink is a useful service for securely sharing resources across VPCs and accounts. It can help achieve
networking goals while maintaining high levels of security and performance. The specific implementation details will
depend on your use case and requirements, but the general principles outlined in this post should provide a good
starting point for understanding and working with PrivateLink.

If you have any issues with the Terraform, you can find a working implementation on my
[GitHub.](https://github.com/incpac/aws-privatelink-demo)
