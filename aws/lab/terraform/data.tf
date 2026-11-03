# ── S3: private, versioned, KMS-encrypted, lifecycle-managed ────────────────
resource "aws_s3_bucket" "artifacts" {
  bucket        = "${var.prefix}-artifacts"
  force_destroy = true
}

resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.lab.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket                  = aws_s3_bucket.artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  rule {
    id     = "expire-old-versions"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}

# ── DynamoDB ────────────────────────────────────────────────────────────────
resource "aws_dynamodb_table" "orders" {
  name         = "${var.prefix}-orders"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "customerId"
  range_key    = "orderId"

  attribute {
    name = "customerId"
    type = "S"
  }
  attribute {
    name = "orderId"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }
  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.lab.arn
  }
}

# ── RDS PostgreSQL (real container on Floci) ────────────────────────────────
resource "aws_db_subnet_group" "lab" {
  name       = "${var.prefix}-db"
  subnet_ids = aws_subnet.private[*].id
}

resource "aws_db_instance" "postgres" {
  identifier                 = "${var.prefix}-pg"
  engine                     = "postgres"
  engine_version             = "16"
  instance_class             = "db.t4g.micro"
  allocated_storage          = 20
  db_name                    = "app"
  username                   = "labadmin"
  password                   = random_password.db.result
  db_subnet_group_name       = aws_db_subnet_group.lab.name
  vpc_security_group_ids     = [aws_security_group.db.id]
  storage_encrypted          = true
  kms_key_id                 = aws_kms_key.lab.arn
  publicly_accessible        = false
  backup_retention_period    = 1
  skip_final_snapshot        = true
  deletion_protection        = false
  auto_minor_version_upgrade = true
}

# ── ElastiCache (Valkey container on Floci) ─────────────────────────────────
resource "aws_elasticache_subnet_group" "lab" {
  name       = "${var.prefix}-cache"
  subnet_ids = aws_subnet.private[*].id
}

resource "aws_elasticache_replication_group" "cache" {
  replication_group_id       = "${var.prefix}-cache"
  description                = "${var.prefix} cache"
  engine                     = "valkey"
  node_type                  = "cache.t4g.micro"
  num_cache_clusters         = 1
  subnet_group_name          = aws_elasticache_subnet_group.lab.name
  security_group_ids         = [aws_security_group.db.id]
  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
  automatic_failover_enabled = false

  lifecycle {
    ignore_changes = [security_group_ids] # devops:approved-ignore not persisted by Floci (A-05)
  }
}

# ── Backup ──────────────────────────────────────────────────────────────────
resource "aws_backup_vault" "lab" {
  name        = "${var.prefix}-vault"
  kms_key_arn = aws_kms_key.lab.arn
}

resource "aws_backup_plan" "daily" {
  name = "${var.prefix}-daily"
  rule {
    rule_name         = "daily"
    target_vault_name = aws_backup_vault.lab.name
    schedule          = "cron(0 3 * * ? *)"
    lifecycle {
      delete_after = 14
    }
  }

  lifecycle {
    ignore_changes = [tags, tags_all] # dropped by Floci (A-06)
  }
}
