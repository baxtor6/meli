# ---------------------------------------------------------------------------
# Bucket S3 para los access logs del ALB.
#
# En la Opción A el ALB lo crea el AWS Load Balancer Controller a partir del
# Ingress (ver k8s/base/ingress.yaml), NO Terraform. Pero el bucket de
# logs sí es un insumo de infraestructura base, así que vive aquí; el Ingress
# lo referencia por nombre vía la annotation
# `alb.ingress.kubernetes.io/load-balancer-attributes` (access_logs.s3.bucket).
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "alb_logs" {
  bucket = "${var.project_name}-alb-logs"

  tags = { Name = "${var.project_name}-alb-logs" }
}

resource "aws_s3_bucket_public_access_block" "alb_logs" {
  bucket                  = aws_s3_bucket.alb_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
