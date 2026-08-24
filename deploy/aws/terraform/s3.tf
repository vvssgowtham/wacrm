# ---------------------------------------------------------------
# S3 bucket backing Supabase Storage
#
# The app creates three buckets in SQL (migrations 008, 016, 023):
# `avatars`, `flow-media`, `chat-media`. Those are Supabase Storage
# buckets — rows in `storage.buckets` — not S3 buckets. All three live
# as key prefixes inside this single S3 bucket, and storage-api
# enforces the per-bucket RLS on `storage.objects`.
#
# Public reads go through storage-api at
#   /storage/v1/object/public/<bucket>/<path>
# not through S3 directly, which is why the S3 bucket itself stays
# fully private. Meta fetches outbound media over that Kong route.
# ---------------------------------------------------------------

resource "random_id" "bucket_suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "storage" {
  bucket = "${local.name}-storage-${random_id.bucket_suffix.hex}"

  tags = { Name = "${local.name}-storage" }
}

resource "aws_s3_bucket_public_access_block" "storage" {
  bucket = aws_s3_bucket.storage.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "storage" {
  bucket = aws_s3_bucket.storage.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "storage" {
  bucket = aws_s3_bucket.storage.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "storage" {
  bucket = aws_s3_bucket.storage.id

  # storage-api uses multipart uploads for larger files; an
  # interrupted upload otherwise bills forever as invisible storage.
  rule {
    id     = "abort-incomplete-multipart"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}
