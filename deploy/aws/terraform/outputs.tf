output "app_url" {
  description = "Open this in a browser. Also the value to give Meta as your webhook host."
  value       = local.app_url
}

output "supabase_url" {
  description = "NEXT_PUBLIC_SUPABASE_URL. The self-hosted Supabase gateway."
  value       = local.supabase_url
}

output "whatsapp_webhook_url" {
  description = "Paste this into Meta for Developers -> WhatsApp -> Configuration -> Callback URL."
  value       = "${local.app_url}/api/whatsapp/webhook"
}

output "instance_id" {
  description = "Shell in with: aws ssm start-session --target <this>"
  value       = aws_instance.app.id
}

output "ssm_session_command" {
  description = "Ready-to-paste shell command."
  value       = "aws ssm start-session --target ${aws_instance.app.id} --region ${var.aws_region}"
}

output "instance_public_ip" {
  description = "Stable egress IP of the application instance."
  value       = aws_eip.app.public_ip
}

output "db_endpoint" {
  description = "RDS endpoint. Only reachable from inside the VPC."
  value       = aws_db_instance.main.address
}

output "s3_bucket" {
  description = "S3 bucket backing Supabase Storage."
  value       = aws_s3_bucket.storage.id
}

output "secret_id" {
  description = "Secrets Manager secret holding every generated credential."
  value       = aws_secretsmanager_secret.config.id
}

output "read_secrets_command" {
  description = "Prints the generated secrets, including the anon and service_role keys' signing secret."
  value       = "aws secretsmanager get-secret-value --secret-id ${aws_secretsmanager_secret.config.id} --region ${var.aws_region} --query SecretString --output text | jq ."
}

output "set_meta_app_secret_command" {
  description = "Template for filling in your Meta credentials after the first apply."
  value       = <<-EOT
    aws secretsmanager get-secret-value --secret-id ${aws_secretsmanager_secret.config.id} --region ${var.aws_region} --query SecretString --output text \
      | jq '.META_APP_SECRET="<your-meta-app-secret>" | .META_APP_ID="<your-meta-app-id>"' \
      | aws secretsmanager put-secret-value --secret-id ${aws_secretsmanager_secret.config.id} --region ${var.aws_region} --secret-string file:///dev/stdin
  EOT
}

output "ses_sandbox_warning" {
  description = "Reminder about SES production access."
  value = var.ses_from_address == "" ? "SES not configured (ses_from_address is empty) — no auth emails will be sent." : "SES domain identity created for ${var.domain_name}. New AWS accounts are in the SES sandbox: mail is only delivered to individually verified addresses until you request production access."
}
