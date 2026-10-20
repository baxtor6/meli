# ---------------------------------------------------------------------------
# Certificados TLS gestionados por ACM (rotacion automatica).
#
# Se necesitan DOS certificados por una restriccion de AWS:
#   - ALB (regional)       -> certificado en la region de la infra (var.aws_region).
#   - CloudFront (edge)    -> certificado OBLIGATORIAMENTE en us-east-1.
#
# Ambos se validan por DNS creando registros CNAME en la hosted zone de
# Route53 (ver route53.tf). La validacion DNS permite renovacion automatica
# sin intervencion manual.
#
# NOTA (challenge): no se despliega. var.domain_name es un placeholder
# (api.seller-dashboard.example.com) — en real seria el dominio propio.
# ---------------------------------------------------------------------------

# --- Certificado regional para el ALB ---
resource "aws_acm_certificate" "alb" {
  domain_name       = var.domain_name
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = { Name = "${var.project_name}-alb-cert" }
}

resource "aws_acm_certificate_validation" "alb" {
  certificate_arn         = aws_acm_certificate.alb.arn
  validation_record_fqdns = [for record in aws_route53_record.alb_cert_validation : record.fqdn]
}

# --- Certificado en us-east-1 para CloudFront ---
# Cubre el dominio publico (var.cdn_domain_name) servido por el edge.
resource "aws_acm_certificate" "cloudfront" {
  provider = aws.us_east_1

  domain_name       = var.cdn_domain_name
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = { Name = "${var.project_name}-cloudfront-cert" }
}

resource "aws_acm_certificate_validation" "cloudfront" {
  provider = aws.us_east_1

  certificate_arn         = aws_acm_certificate.cloudfront.arn
  validation_record_fqdns = [for record in aws_route53_record.cloudfront_cert_validation : record.fqdn]
}
