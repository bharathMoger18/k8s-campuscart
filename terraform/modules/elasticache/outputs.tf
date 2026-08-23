output "redis_endpoint" {
  description = "Redis primary endpoint — host your Django app (and Channels layer) will connect to."
  value       = aws_elasticache_cluster.main.cache_nodes[0].address
}

output "redis_port" {
  value = aws_elasticache_cluster.main.cache_nodes[0].port
}

output "security_group_id" {
  value = aws_security_group.redis.id
}
