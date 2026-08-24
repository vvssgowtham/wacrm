# ---------------------------------------------------------------
# SES domain identity + DKIM
#
# Terraform can verify the domain and publish the DKIM records, but it
# CANNOT get you out of the SES sandbox. Until you request production
# access (README step 8), SES only delivers to addresses you have
# individually verified — everything else is accepted and silently
# dropped. That is the single most common "invites never arrive"
# cause on a fresh AWS account.
# ---------------------------------------------------------------

data "aws_route53_zone" "main" {
  name         = var.domain_name
  private_zone = false
}

resource "aws_ses_domain_identity" "main" {
  count  = var.ses_from_address == "" ? 0 : 1
  domain = var.domain_name
}

resource "aws_ses_domain_dkim" "main" {
  count  = var.ses_from_address == "" ? 0 : 1
  domain = aws_ses_domain_identity.main[0].domain
}

resource "aws_route53_record" "ses_dkim" {
  count = var.ses_from_address == "" ? 0 : 3

  zone_id = data.aws_route53_zone.main.zone_id
  name    = "${aws_ses_domain_dkim.main[0].dkim_tokens[count.index]}._domainkey.${var.domain_name}"
  type    = "CNAME"
  ttl     = 600
  records = ["${aws_ses_domain_dkim.main[0].dkim_tokens[count.index]}.dkim.amazonses.com"]
}

resource "aws_ses_domain_identity_verification" "main" {
  count  = var.ses_from_address == "" ? 0 : 1
  domain = aws_ses_domain_identity.main[0].id

  depends_on = [aws_route53_record.ses_dkim]
}

# Lets receiving mail servers see a From domain that SES is
# authorised for, which materially improves deliverability.
#
# Route 53 allows exactly one TXT record set per name, so if the apex
# already carries TXT records (Google Workspace verification, an
# existing SPF, ...) this apply fails with "it already exists". Set
# manage_spf_record = false and merge `include:amazonses.com` into
# your existing SPF string by hand.
resource "aws_route53_record" "ses_spf" {
  count = var.ses_from_address != "" && var.manage_spf_record ? 1 : 0

  zone_id = data.aws_route53_zone.main.zone_id
  name    = var.domain_name
  type    = "TXT"
  ttl     = 600
  records = ["v=spf1 include:amazonses.com ~all"]
}
