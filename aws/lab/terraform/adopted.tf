# Day-2 T1 (AWS): bucket created by hand, adopted with an import block + generated config.
# Adopted with an import block (terraform plan -generate-config-out, reviewed); the block was
# removed after the apply, as import blocks are one-shot.

# Generated block, reviewed: computed tags_all and provider defaults dropped; tags come from
# the provider's default_tags.
resource "aws_s3_bucket" "exports" {
  bucket = "flocilab-manual-exports"
}

# Brought up to the lab's bucket standard in the same change (encrypt_at_rest blocked it as P0).
resource "aws_s3_bucket_server_side_encryption_configuration" "manual_exports" {
  bucket = aws_s3_bucket.exports.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.lab.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "manual_exports" {
  bucket                  = aws_s3_bucket.exports.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# T4: address renamed manual_exports -> exports; moved keeps the bucket and its objects.
moved {
  from = aws_s3_bucket.manual_exports
  to   = aws_s3_bucket.exports
}
