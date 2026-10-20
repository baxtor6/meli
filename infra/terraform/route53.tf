# ---------------------------------------------------------------------------
# Route53 — DNS publico de la plataforma.
#
# Estructura:
#   - Una hosted zone para el dominio raiz (var.root_domain, placeholder).
#   - var.cdn_domain_name  -> ALIAS a la distribucion de CloudFront (entrada
#     publica real; CloudFront luego habla con el ALB como origin).
#   - var.domain_name      -> hostname del ALB (origin). En Opcion A este
#     registro lo crea y mantiene ExternalDNS a partir del Ingress, NO
#     Terraform (por eso no aparece aqui como aws_route53_record).
#   - Registros CNAME de validacion DNS para los dos certificados ACM.
#
# Para failover multi-region (mencionado en architecture.md) se usarian
# registros con routing_policy = "failover" + health checks; aqui se deja
# el caso de una sola region para mantener el ejemplo acotado.
#
# NOTA (challenge): no se despliega. En real, el dominio ya debe existir y
# delegarse a los name servers que esta zona genera (output route53_name_servers).
# ---------------------------------------------------------------------------

resource "aws_route53_zone" "main" {
  name = var.root_domain

  tags = { Name = "${var.project_name}-zone" }
}

# --- Entrada publica: dominio del API -> CloudFront ---
resource "aws_route53_record" "cdn" {
  zone_id = aws_route53_zone.main.zone_id
  name    = var.cdn_domain_name
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.api.domain_name
    zone_id                = aws_cloudfront_distribution.api.hosted_zone_id
    evaluate_target_health = false
  }
}

# --- Hostname del ALB (origin) ---
# En Opcion A lo gestiona ExternalDNS (controller en el cluster) a partir de
# la annotation `external-dns.alpha.kubernetes.io/hostname` del Ingress, que
# apunta a var.domain_name. No se declara aqui para no competir con el
# controller por el mismo registro (una sola fuente de verdad).

# --- Registros de validacion DNS del certificado del ALB ---
resource "aws_route53_record" "alb_cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.alb.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  zone_id         = aws_route53_zone.main.zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

# --- Registros de validacion DNS del certificado de CloudFront ---
resource "aws_route53_record" "cloudfront_cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.cloudfront.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  zone_id         = aws_route53_zone.main.zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}
