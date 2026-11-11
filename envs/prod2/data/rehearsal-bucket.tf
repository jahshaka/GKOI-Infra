# The private go-live rehearsal's SCRATCH recordings bucket (envs/prod2/rehearsal/README.md). With compute's and
# media's `rehearsal = true` the engine (S3_BUCKET) and every media box (the agent's S3_BUCKET) record here, and their
# roles reach only this bucket — never gkoi-beta-vods, the live one. Here (not in compute or media) because both of
# those read this stack's outputs already: data → compute → media, no stack reading a later one.
#
# Private (public access blocked, owner-enforced), SSE-S3, TLS only, every object expires after
# rehearsal_vods_days, force_destroy (a scratch bucket: nothing in it is kept). Nothing references it while the
# switches are off; it costs nothing empty.

variable "rehearsal_vods_bucket" {
  type    = string
  default = "gkoi-prod2-rehearsal-vods-127214190346"
}

variable "rehearsal_vods_days" {
  description = "Every object of the scratch bucket expires this many days after it was written."
  type        = number
  default     = 3
}

resource "aws_s3_bucket" "rehearsal_vods" {
  bucket        = var.rehearsal_vods_bucket
  force_destroy = true
  tags          = { Name = var.rehearsal_vods_bucket, purpose = "rehearsal-scratch" }
}

resource "aws_s3_bucket_public_access_block" "rehearsal_vods" {
  bucket                  = aws_s3_bucket.rehearsal_vods.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "rehearsal_vods" {
  bucket = aws_s3_bucket.rehearsal_vods.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "rehearsal_vods" {
  bucket = aws_s3_bucket.rehearsal_vods.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "rehearsal_vods" {
  bucket = aws_s3_bucket.rehearsal_vods.id
  rule {
    id     = "expire-rehearsal-recordings"
    status = "Enabled"
    filter {}
    expiration {
      days = var.rehearsal_vods_days
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

data "aws_iam_policy_document" "rehearsal_vods" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    resources = [aws_s3_bucket.rehearsal_vods.arn, "${aws_s3_bucket.rehearsal_vods.arn}/*"]
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "rehearsal_vods" {
  bucket     = aws_s3_bucket.rehearsal_vods.id
  policy     = data.aws_iam_policy_document.rehearsal_vods.json
  depends_on = [aws_s3_bucket_public_access_block.rehearsal_vods]
}

output "rehearsal_vods_bucket" {
  description = "The rehearsal's scratch recordings bucket (compute + media `rehearsal = true` point the engine and the boxes at it)."
  value = {
    name   = aws_s3_bucket.rehearsal_vods.id
    arn    = aws_s3_bucket.rehearsal_vods.arn
    region = "us-west-2"
    days   = var.rehearsal_vods_days
  }
}
