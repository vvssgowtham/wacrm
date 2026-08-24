# ---------------------------------------------------------------
# Scheduled cron pingers
#
# Nothing inside the container is scheduled. Automation "Wait" steps
# and scheduled flows sit in a pending state until something calls
#   GET /api/automations/cron
#   GET /api/flows/cron
# with the shared secret in an `x-cron-secret` header. Both routes
# answer 503 until AUTOMATION_CRON_SECRET is set, which it is —
# Terraform generates it and deploy.sh writes it into the app's env.
#
# EventBridge API destinations do this natively: a Connection holds
# the header, an API Destination holds the URL, and a scheduled Rule
# fires it. No Lambda, no code, no cold starts.
# ---------------------------------------------------------------

resource "aws_cloudwatch_event_connection" "cron" {
  name               = "${local.name}-cron"
  description        = "Shared secret for the wacrm cron endpoints"
  authorization_type = "API_KEY"

  auth_parameters {
    api_key {
      key   = "x-cron-secret"
      value = random_id.cron_secret.hex
    }
  }
}

resource "aws_cloudwatch_event_api_destination" "automations" {
  name                             = "${local.name}-automations-cron"
  invocation_endpoint              = "${local.app_url}/api/automations/cron"
  http_method                      = "GET"
  connection_arn                   = aws_cloudwatch_event_connection.cron.arn
  invocation_rate_limit_per_second = 1
}

resource "aws_cloudwatch_event_api_destination" "flows" {
  name                             = "${local.name}-flows-cron"
  invocation_endpoint              = "${local.app_url}/api/flows/cron"
  http_method                      = "GET"
  connection_arn                   = aws_cloudwatch_event_connection.cron.arn
  invocation_rate_limit_per_second = 1
}

data "aws_iam_policy_document" "events_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "events" {
  name               = "${local.name}-events"
  assume_role_policy = data.aws_iam_policy_document.events_assume.json
}

resource "aws_iam_role_policy" "events" {
  name = "${local.name}-invoke-api-destinations"
  role = aws_iam_role.events.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["events:InvokeApiDestination"]
      Resource = [
        aws_cloudwatch_event_api_destination.automations.arn,
        aws_cloudwatch_event_api_destination.flows.arn,
      ]
    }]
  })
}

resource "aws_cloudwatch_event_rule" "cron" {
  name                = "${local.name}-cron"
  description         = "Drains pending automation waits and scheduled flows"
  schedule_expression = var.cron_schedule_expression
}

resource "aws_cloudwatch_event_target" "automations" {
  rule     = aws_cloudwatch_event_rule.cron.name
  target_id = "automations"
  arn      = aws_cloudwatch_event_api_destination.automations.arn
  role_arn = aws_iam_role.events.arn

  retry_policy {
    maximum_event_age_in_seconds = 120
    maximum_retry_attempts       = 2
  }
}

resource "aws_cloudwatch_event_target" "flows" {
  rule      = aws_cloudwatch_event_rule.cron.name
  target_id = "flows"
  arn       = aws_cloudwatch_event_api_destination.flows.arn
  role_arn  = aws_iam_role.events.arn

  retry_policy {
    maximum_event_age_in_seconds = 120
    maximum_retry_attempts       = 2
  }
}
