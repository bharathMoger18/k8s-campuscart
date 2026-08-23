output "db_endpoint" {
  description = "RDS connection endpoint — host:port your Django app will connect to."
  value       = aws_db_instance.main.endpoint
}

output "db_name" {
  value = aws_db_instance.main.db_name
}

output "db_secret_arn" {
  description = "ARN of the Secrets Manager secret holding the DB password — your app fetches the actual password from here at runtime, never from a hardcoded value."
  value       = aws_secretsmanager_secret.db_password.arn
}

output "security_group_id" {
  description = "RDS security group ID — exposed in case other modules need to reference it."
  value       = aws_security_group.rds.id
}
