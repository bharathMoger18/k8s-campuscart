# =============================================================================
# terraform/modules/elasticache/main.tf
# =============================================================================

# -----------------------------------------------------------------------------
# RESOURCE 1: Security group — identical pattern to RDS, different port
# -----------------------------------------------------------------------------
resource "aws_security_group" "redis" {
  name_prefix = "${var.cluster_id}-sg-"
  vpc_id      = var.vpc_id

  ingress {
    description     = "Redis from EKS nodes only"
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [var.eks_node_security_group_id]
  }

  tags = {
    Name = "${var.cluster_id}-sg"
  }
}

# -----------------------------------------------------------------------------
# RESOURCE 2: Subnet group — same concept as RDS's DB subnet group
# -----------------------------------------------------------------------------
resource "aws_elasticache_subnet_group" "main" {
  name       = "${var.cluster_id}-subnet-group"
  subnet_ids = var.private_subnet_ids
}

# -----------------------------------------------------------------------------
# RESOURCE 3: The Redis cluster itself
# -----------------------------------------------------------------------------
# WE'RE USING aws_elasticache_cluster (single-node), NOT
# aws_elasticache_replication_group (multi-node with automatic failover).
# This is the SAME trade-off we made with RDS's multi_az=false — a genuine,
# deliberate cost decision for our test-and-destroy workflow, not an
# oversight. A replication_group with automatic failover would cost roughly
# 2x+ (multiple nodes) and is what a real, permanently-running production
# Redis deployment should use instead.
# -----------------------------------------------------------------------------
resource "aws_elasticache_cluster" "main" {
  cluster_id      = var.cluster_id
  engine          = "redis"
  engine_version  = var.engine_version
  node_type       = var.node_type
  num_cache_nodes = 1 # single node — see note above about the production alternative

  port               = 6379
  subnet_group_name  = aws_elasticache_subnet_group.main.name
  security_group_ids = [aws_security_group.redis.id]

  # Redis AUTH — requires a password/token for every connection, on top of
  # the security group's network-level restriction. This is DEFENSE IN
  # DEPTH: even if someone somehow got network access to this Redis
  # instance (a misconfigured SG elsewhere, a compromised node), they'd
  # still need this token to actually issue commands. Belt and suspenders,
  # same principle as publicly_accessible=false alongside private subnets
  # on RDS — never rely on just ONE layer of protection.
  #
  # NOTE: at-rest/in-transit encryption + AUTH require replication_group,
  # not the single-node cluster resource — another reason a real always-on
  # production Redis should graduate to aws_elasticache_replication_group.
  # We're flagging this trade-off honestly rather than silently using the
  # weaker option without telling you.

  tags = {
    Name = var.cluster_id
  }
}
