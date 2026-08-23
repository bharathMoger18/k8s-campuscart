# =============================================================================
# terraform/modules/rds/main.tf
# =============================================================================

# -----------------------------------------------------------------------------
# RESOURCE 1: Generate a strong random password — never hand-type this
# -----------------------------------------------------------------------------
# WHY: A human-chosen password is almost always weaker than it should be,
# and typing it into a .tfvars file (even a gitignored one) means it now
# exists in plaintext on your laptop's disk. `random_password` generates a
# cryptographically random value at apply-time, stored only in Terraform
# state (which we've already secured — encrypted, access-controlled S3).
# -----------------------------------------------------------------------------
resource "random_password" "db_password" {
  length  = 24
  special = true
  # RDS disallows a few specific special characters in passwords
  # (/, @, ", and space) — this excludes exactly those, nothing more.
  override_special = "!#$%^&*()-_=+[]{}<>:?"
}

# -----------------------------------------------------------------------------
# RESOURCE 2: Store that password in AWS Secrets Manager
# -----------------------------------------------------------------------------
# WHY NOT JUST LEAVE IT IN TERRAFORM STATE: State is encrypted and access-
# controlled, which is a reasonable baseline — but Secrets Manager gives
# you things state alone doesn't: fine-grained IAM access policies specific
# to secret access, automatic rotation support, and — critically — a way
# for OTHER systems (like your Django app running in EKS) to fetch this
# password at RUNTIME without it ever being baked into a Docker image, a
# Kubernetes ConfigMap, or an environment variable checked into any repo.
# This is genuinely how real production secret management works.
# -----------------------------------------------------------------------------
resource "aws_secretsmanager_secret" "db_password" {
  name                    = "${var.identifier}-db-password"
  recovery_window_in_days = 0 # 0 = delete immediately on destroy, no 7-30 day recovery hold — correct for our test-and-destroy workflow, NOT what you'd set for a real always-on production secret
}

resource "aws_secretsmanager_secret_version" "db_password" {
  secret_id     = aws_secretsmanager_secret.db_password.id
  secret_string = random_password.db_password.result
}

# -----------------------------------------------------------------------------
# RESOURCE 3: Security group — the firewall rule from our diagram
# -----------------------------------------------------------------------------
resource "aws_security_group" "rds" {
  name_prefix = "${var.identifier}-sg-"
  vpc_id      = var.vpc_id

  ingress {
    description     = "PostgreSQL from EKS nodes only"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [var.eks_node_security_group_id] # THIS is the "reference another SG, not a CIDR" pattern from the diagram
  }

  # Deliberately NO egress rule restriction here — RDS itself doesn't
  # initiate outbound connections in any way that matters for our setup,
  # so the AWS default (allow all outbound) is harmless in this specific
  # case. We'll be stricter with egress where it actually matters.

  tags = {
    Name = "${var.identifier}-sg"
  }
}

# -----------------------------------------------------------------------------
# RESOURCE 4: DB subnet group — tells RDS WHICH subnets it's allowed to use
# -----------------------------------------------------------------------------
# RDS instances, like EKS nodes, need to live inside specific subnets.
# A "DB subnet group" is simply the named set of subnets RDS is allowed to
# place its actual database instance (and any standby, for Multi-AZ) into.
# We pass ONLY private subnets — this database will never have a public IP
# or a direct route to the internet, full stop.
# -----------------------------------------------------------------------------
resource "aws_db_subnet_group" "main" {
  name       = "${var.identifier}-subnet-group"
  subnet_ids = var.private_subnet_ids

  tags = {
    Name = "${var.identifier}-subnet-group"
  }
}

# -----------------------------------------------------------------------------
# RESOURCE 5: The actual RDS instance
# -----------------------------------------------------------------------------
resource "aws_db_instance" "main" {
  identifier     = var.identifier
  engine         = "postgres"
  engine_version = var.engine_version
  instance_class = var.instance_class

  allocated_storage = var.allocated_storage
  storage_type      = "gp3"
  storage_encrypted = true # encryption at rest — non-negotiable for anything holding user data (your users table, orders, payments records)

  db_name  = var.db_name
  username = var.db_username
  password = random_password.db_password.result

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false # belt-and-suspenders alongside the private subnet placement — explicitly, structurally not internet-reachable

  # -------------------------------------------------------------------------
  # HONEST COST-VS-DURABILITY TRADE-OFFS, MADE DELIBERATELY, NOT BY ACCIDENT:
  # -------------------------------------------------------------------------
  multi_az = false
  # multi_az=true would create a live standby replica in the SECOND AZ,
  # with automatic failover if the primary fails — genuinely what a real,
  # always-on production database should have. It roughly DOUBLES the RDS
  # cost, since you're paying for two instances. For our spin-up-test-
  # destroy-within-an-hour workflow, that redundancy has no chance to ever
  # matter, so we're deliberately choosing false — but if this were staying
  # up permanently serving real users, this should be true.

  backup_retention_period = 1
  # How many days of automated backups RDS keeps. Production systems
  # typically want 7-30 days for real point-in-time recovery options. We
  # set the practical minimum here since we're tearing this down shortly
  # anyway — backups we'll never use aren't worth the (small) storage cost.

  skip_final_snapshot = true
  # On destroy, RDS normally forces you to take a final backup snapshot
  # before it'll let the instance be deleted — a safety net against
  # accidental data loss. We're explicitly skipping that, because we WANT
  # `terraform destroy` to complete cleanly and quickly for our test run.
  # In a real production database, this should be FALSE — you want that
  # final safety net, always.

  deletion_protection = false
  # AWS-level "refuse to delete this no matter what" switch, similar in
  # spirit to prevent_destroy in Terraform, but enforced by AWS itself even
  # against direct console/CLI deletion attempts. Real production databases
  # should have this ON. We're keeping it off specifically because we plan
  # to destroy this within the hour, deliberately.

  tags = {
    Name = var.identifier
  }
}
