# ---------------------------------------------------------------
# ACM certificate
#
# One certificate covering both hostnames. Meta refuses to register a
# WhatsApp webhook without a publicly trusted certificate, so this is
# load-bearing, not decoration.
# ---------------------------------------------------------------

resource "aws_acm_certificate" "main" {
  domain_name               = local.app_fqdn
  subject_alternative_names = [local.supabase_fqdn]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = { Name = "${local.name}-cert" }
}

resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.main.domain_validation_options :
    dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  zone_id         = data.aws_route53_zone.main.zone_id
  name            = each.value.name
  type            = each.value.type
  ttl             = 60
  records         = [each.value.record]
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "main" {
  certificate_arn         = aws_acm_certificate.main.arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}

# ---------------------------------------------------------------
# Application Load Balancer
# ---------------------------------------------------------------

resource "aws_lb" "main" {
  name               = substr("${local.name}-alb", 0, 32)
  load_balancer_type = "application"
  internal           = false
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id

  # Realtime's WebSocket sends a heartbeat every 30s, comfortably
  # inside the 60s default, but broadcast sends and CSV imports can
  # hold a request open longer than that. 300s costs nothing and
  # removes a class of mystery 504s.
  idle_timeout = 300

  enable_http2               = true
  drop_invalid_header_fields = true

  tags = { Name = "${local.name}-alb" }
}

resource "aws_lb_target_group" "app" {
  name     = substr("${local.name}-app", 0, 32)
  port     = 3000
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    path = "/login"
    # /login is public and cheap. Its middleware calls
    # supabase.auth.getUser(), which short-circuits to null with no
    # network call when the request carries no session cookie — so
    # this checks the app, not the whole Supabase stack.
    matcher             = "200"
    interval            = 30
    timeout             = 10
    healthy_threshold   = 2
    unhealthy_threshold = 5
  }

  deregistration_delay = 30

  tags = { Name = "${local.name}-app-tg" }
}

resource "aws_lb_target_group" "supabase" {
  name     = substr("${local.name}-supabase", 0, 32)
  port     = 8000
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    # ALB health checks cannot send custom headers, so every
    # key-auth-protected Kong route answers 401. kong.template.yml
    # therefore exposes GoTrue's /health through an unauthenticated
    # route specifically for this check.
    path                = "/auth/v1/health"
    matcher             = "200"
    interval            = 30
    timeout             = 10
    healthy_threshold   = 2
    unhealthy_threshold = 5
  }

  # Realtime holds long-lived WebSockets; draining them abruptly on
  # every deploy would drop the inbox's live updates.
  deregistration_delay = 60

  # Kong routes /realtime/v1 to a WebSocket upstream. Sticky sessions
  # keep a reconnecting client on the same target — irrelevant with a
  # single instance today, correct the day you add a second.
  stickiness {
    type            = "lb_cookie"
    cookie_duration = 86400
    enabled         = true
  }

  tags = { Name = "${local.name}-supabase-tg" }
}

resource "aws_lb_target_group_attachment" "app" {
  target_group_arn = aws_lb_target_group.app.arn
  target_id        = aws_instance.app.id
  port             = 3000
}

resource "aws_lb_target_group_attachment" "supabase" {
  target_group_arn = aws_lb_target_group.supabase.arn
  target_id        = aws_instance.app.id
  port             = 8000
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.main.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

# Host-based split: everything on the supabase subdomain goes to Kong,
# everything else falls through to the app (the listener default).
resource "aws_lb_listener_rule" "supabase" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 10

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.supabase.arn
  }

  condition {
    host_header {
      values = [local.supabase_fqdn]
    }
  }
}

# ---------------------------------------------------------------
# DNS
# ---------------------------------------------------------------

resource "aws_route53_record" "app" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = local.app_fqdn
  type    = "A"

  alias {
    name                   = aws_lb.main.dns_name
    zone_id                = aws_lb.main.zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "supabase" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = local.supabase_fqdn
  type    = "A"

  alias {
    name                   = aws_lb.main.dns_name
    zone_id                = aws_lb.main.zone_id
    evaluate_target_health = true
  }
}
