# ---------------------------------------------------------------
# Instance role
#
# storage-api talks to S3 through the AWS SDK, which picks up the
# instance profile automatically. That is why no AWS access keys
# appear anywhere in docker-compose.yml or the .env file — the
# container inherits credentials from the instance metadata service.
# ---------------------------------------------------------------

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "app" {
  name               = "${local.name}-app"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

# SSM Session Manager: shell access with no open SSH port and no key
# pair. `aws ssm start-session --target <instance-id>`.
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.app.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "app" {
  statement {
    sid    = "ReadRuntimeConfig"
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]
    resources = [aws_secretsmanager_secret.config.arn]
  }

  statement {
    sid    = "StorageObjects"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:AbortMultipartUpload",
      "s3:ListMultipartUploadParts",
      "s3:GetObjectTagging",
      "s3:PutObjectTagging",
    ]
    resources = ["${aws_s3_bucket.storage.arn}/*"]
  }

  statement {
    sid    = "StorageBucket"
    effect = "Allow"
    actions = [
      "s3:ListBucket",
      "s3:GetBucketLocation",
      "s3:ListBucketMultipartUploads",
    ]
    resources = [aws_s3_bucket.storage.arn]
  }

  statement {
    sid       = "WriteLogs"
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
    resources = ["${aws_cloudwatch_log_group.app.arn}:*"]
  }
}

resource "aws_iam_role_policy" "app" {
  name   = "${local.name}-app"
  role   = aws_iam_role.app.id
  policy = data.aws_iam_policy_document.app.json
}

resource "aws_iam_instance_profile" "app" {
  name = "${local.name}-app"
  role = aws_iam_role.app.name
}

resource "aws_cloudwatch_log_group" "app" {
  name              = "/${local.name}/bootstrap"
  retention_in_days = 30
}

# ---------------------------------------------------------------
# SES SMTP user
#
# GoTrue speaks SMTP, not the SES API, so it needs SMTP credentials.
# SES derives the SMTP password from an IAM secret access key using a
# documented HMAC — `ses_smtp_password_v4` is Terraform doing that
# derivation, not the raw secret key.
#
# This is the one place a static credential is unavoidable; it is
# scoped to sending mail and nothing else.
# ---------------------------------------------------------------

resource "aws_iam_user" "ses" {
  count = var.ses_from_address == "" ? 0 : 1
  name  = "${local.name}-ses-smtp"
}

data "aws_iam_policy_document" "ses" {
  count = var.ses_from_address == "" ? 0 : 1

  statement {
    effect    = "Allow"
    actions   = ["ses:SendRawEmail", "ses:SendEmail"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "ses:FromAddress"
      values   = [var.ses_from_address]
    }
  }
}

resource "aws_iam_user_policy" "ses" {
  count  = var.ses_from_address == "" ? 0 : 1
  name   = "${local.name}-ses-send"
  user   = aws_iam_user.ses[0].name
  policy = data.aws_iam_policy_document.ses[0].json
}

resource "aws_iam_access_key" "ses" {
  count = var.ses_from_address == "" ? 0 : 1
  user  = aws_iam_user.ses[0].name
}
