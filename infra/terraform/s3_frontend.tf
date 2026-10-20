# ---------------------------------------------------------------------------
# Bucket S3 para la SPA del frontend (Vite build -> dist/).
#
# La SPA es 100% estatica (HTML/CSS/JS), asi que se sirve desde S3 + CloudFront
# en vez de desde pods de EKS: mas barato, mas cerca del usuario y descarga al
# backend. El bucket es PRIVADO: solo CloudFront puede leerlo, via Origin
# Access Control (OAC). No se habilita website-hosting de S3 (no hace falta:
# el fallback SPA lo resuelve CloudFront con custom_error_response).
#
# El pipeline publica el build con `aws s3 sync dist/ s3://<bucket> --delete`
# y luego invalida la distribucion (output: cloudfront_distribution_id).
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "frontend" {
  bucket = "${var.project_name}-frontend"

  tags = { Name = "${var.project_name}-frontend" }
}

# Bucket privado: nada publico. El acceso es exclusivamente via CloudFront+OAC.
resource "aws_s3_bucket_public_access_block" "frontend" {
  bucket                  = aws_s3_bucket.frontend.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "frontend" {
  bucket = aws_s3_bucket.frontend.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Origin Access Control: identidad firmada (SigV4) con la que CloudFront accede
# al bucket privado. Reemplaza al legacy Origin Access Identity (OAI).
resource "aws_cloudfront_origin_access_control" "frontend" {
  name                              = "${var.project_name}-frontend-oac"
  description                       = "OAC para que CloudFront lea el bucket privado de la SPA"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# Policy del bucket: permite s3:GetObject SOLO a la distribucion CloudFront
# concreta (condicion AWS:SourceArn), no a cualquier principal de CloudFront.
data "aws_iam_policy_document" "frontend" {
  statement {
    sid       = "AllowCloudFrontRead"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.frontend.arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.api.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "frontend" {
  bucket = aws_s3_bucket.frontend.id
  policy = data.aws_iam_policy_document.frontend.json
}
