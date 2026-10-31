# ── TLS: a self-signed certificate imported into ACM (no DNS validation in a lab) ──
resource "tls_private_key" "alb" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "alb" {
  private_key_pem       = tls_private_key.alb.private_key_pem
  validity_period_hours = 24 * 90
  allowed_uses          = ["key_encipherment", "digital_signature", "server_auth"]
  dns_names             = ["app.${var.prefix}.internal"]
  subject {
    common_name = "app.${var.prefix}.internal"
  }
}

resource "aws_acm_certificate" "alb" {
  private_key      = tls_private_key.alb.private_key_pem
  certificate_body = tls_self_signed_cert.alb.cert_pem
}

# ── Application Load Balancer: HTTPS only, to the app tier ──────────────────
resource "aws_lb" "app" {
  name                       = "${var.prefix}-alb"
  load_balancer_type         = "application"
  internal                   = false
  subnets                    = aws_subnet.public[*].id
  security_groups            = [aws_security_group.alb.id]
  drop_invalid_header_fields = true
}

resource "aws_lb_target_group" "app" {
  name        = "${var.prefix}-app"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = aws_vpc.lab.id
  target_type = "ip"
  health_check {
    path    = "/healthz"
    matcher = "200"
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.app.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate.alb.arn
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

resource "aws_route53_record" "app" {
  zone_id = aws_route53_zone.internal.zone_id
  name    = "app.${var.prefix}.internal"
  type    = "A"
  alias {
    name                   = aws_lb.app.dns_name
    zone_id                = aws_lb.app.zone_id
    evaluate_target_health = false
  }
}

# ── EC2: a bastion-style instance (Floci runs it as a container) ────────────
resource "tls_private_key" "ec2" {
  algorithm = "ED25519"
}

resource "aws_key_pair" "lab" {
  key_name   = "${var.prefix}-key"
  public_key = tls_private_key.ec2.public_key_openssh
  lifecycle {
    ignore_changes = [tags, tags_all] # dropped by Floci (A-06)
  }
}

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

resource "aws_launch_template" "app" {
  name_prefix   = "${var.prefix}-app-"
  image_id      = data.aws_ami.al2023.id
  instance_type = "t3.micro"
  key_name      = aws_key_pair.lab.key_name
  metadata_options {
    http_tokens                 = "required" # IMDSv2 only
    http_put_response_hop_limit = 1
  }
  vpc_security_group_ids = [aws_security_group.app.id]
}

resource "aws_instance" "app" {
  subnet_id = aws_subnet.private[0].id
  launch_template {
    id      = aws_launch_template.app.id
    version = "$Latest"
  }
  root_block_device {
    encrypted  = true
    kms_key_id = aws_kms_key.lab.arn
  }
  tags = { Name = "${var.prefix}-app" }

  lifecycle {
    # Floci 2.3.0 does not keep launch_template or the root volume's encryption (A-04):
    # it reads back unencrypted, which would replace the instance on every plan.
    ignore_changes = [launch_template, root_block_device]
  }
}
