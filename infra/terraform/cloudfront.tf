# ---------------------------------------------------------------------------
# CloudFront — una sola distribucion, DOS origenes (patron SPA + API):
#
#   - Origin S3 (SPA): comportamiento POR DEFECTO. Sirve el build estatico de
#     Vita (index.html + assets con hash). Bucket privado via OAC (s3_frontend.tf).
#   - Origin ALB (API): comportamiento ordenado "/api/*". Reenvia al ALB que
#     crea el AWS Load Balancer Controller (Opcion A), sin cachear.
#
# Reparto por PATH (CloudFront enruta por path dentro de una distribucion):
#   /api/*  -> ALB (API dinamica)         [ordered_cache_behavior]
#   /*      -> S3  (SPA estatica)          [default_cache_behavior]
#
# Fallback SPA: para rutas del lado cliente (ej. /orders/123) el objeto no
# existe en S3. Se resuelve con una CloudFront Function (viewer-request) SOLO
# en el behavior por defecto, que reescribe a /index.html las rutas de
# navegacion (las que no piden un asset con extension). NO se usa
# custom_error_response porque este aplica a TODA la distribucion y convertiria
# tambien los 403/404 legitimos de /api/* en index.html (rompiendo la API).
#
# Rewrite del prefijo: el backend responde en "/..." (no en "/api/..."), asi
# que otra CloudFront Function (viewer-request) quita el prefijo "/api" antes de
# ir al origin ALB. Asi no hay que tocar el codigo del backend ni el Ingress.
#
# Rol general del edge: TLS en us-east-1 (ACM), WAF de edge, absorcion de picos
# y DDoS (Shield Standard).
# ---------------------------------------------------------------------------

locals {
  alb_origin_id = "${var.project_name}-alb-origin"
  s3_origin_id  = "${var.project_name}-s3-spa-origin"
}

# CloudFront Function: quita el prefijo "/api" del URI para el behavior /api/*.
# Ej: viewer pide /api/orders -> al ALB le llega /orders.
resource "aws_cloudfront_function" "strip_api_prefix" {
  name    = "${var.project_name}-strip-api-prefix"
  runtime = "cloudfront-js-2.0"
  comment = "Quita el prefijo /api antes de reenviar al origin ALB"
  publish = true
  code    = <<-EOT
    function handler(event) {
      var req = event.request;
      // /api        -> /
      // /api/orders -> /orders
      req.uri = req.uri.replace(/^\/api(\/|$)/, '/');
      return req;
    }
  EOT
}

# CloudFront Function: fallback SPA en el behavior por defecto (S3).
# Si el URI no apunta a un archivo (no tiene extension, ej. /orders/123),
# se reescribe a /index.html para que el router del browser tome el control.
# Los assets con extension (.js/.css/.png/...) pasan sin tocar.
resource "aws_cloudfront_function" "spa_fallback" {
  name    = "${var.project_name}-spa-fallback"
  runtime = "cloudfront-js-2.0"
  comment = "Reescribe rutas de navegacion de la SPA a /index.html"
  publish = true
  code    = <<-EOT
    function handler(event) {
      var req = event.request;
      var uri = req.uri;
      // Si no hay extension de archivo en el ultimo segmento, es una ruta de
      // navegacion de la SPA -> servir index.html.
      if (!/\.[a-zA-Z0-9]+$/.test(uri)) {
        req.uri = '/index.html';
      }
      return req;
    }
  EOT
}

resource "aws_cloudfront_distribution" "api" {
  enabled             = true
  comment             = "${var.project_name} edge (SPA + API)"
  is_ipv6_enabled     = true
  price_class         = "PriceClass_100" # NA + Europa; ampliar si hay usuarios en otras regiones
  default_root_object = "index.html"

  # Dominio publico servido por el edge (debe coincidir con el cert ACM)
  aliases = [var.cdn_domain_name]

  # WAF de edge
  web_acl_id = aws_wafv2_web_acl.cloudfront.arn

  # --- Origin 1: S3 (SPA estatica), privado via OAC ---
  origin {
    domain_name              = aws_s3_bucket.frontend.bucket_regional_domain_name
    origin_id                = local.s3_origin_id
    origin_access_control_id = aws_cloudfront_origin_access_control.frontend.id
  }

  # --- Origin 2: ALB (API dinamica) ---
  origin {
    # Hostname estable del ALB publicado por ExternalDNS (no el recurso aws_lb,
    # que en Opcion A no existe en el state de Terraform).
    domain_name = var.domain_name
    origin_id   = local.alb_origin_id

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only" # CloudFront -> ALB siempre por TLS
      origin_ssl_protocols   = ["TLSv1.2"]
    }

    # Secreto compartido para que el ALB acepte solo trafico via CloudFront
    # (se valida con una regla en el listener/WAF). Placeholder para el challenge.
    custom_header {
      name  = "X-Origin-Verify"
      value = "REPLACE_WITH_SECRET_FROM_SECRETS_MANAGER"
    }
  }

  # --- Comportamiento por defecto: SPA estatica desde S3, cache alto ---
  default_cache_behavior {
    target_origin_id       = local.s3_origin_id
    viewer_protocol_policy = "redirect-to-https"

    allowed_methods = ["GET", "HEAD", "OPTIONS"]
    cached_methods  = ["GET", "HEAD"]

    # Managed policy "CachingOptimized" — ideal para estaticos con hash en el
    # nombre (assets inmutables). El index.html lo revalida la invalidacion
    # que corre el pipeline en cada deploy del frontend.
    cache_policy_id = "658327ea-f89d-4fab-a63d-7e88639e58f6"

    # Fallback SPA: rutas de navegacion -> /index.html (ver funcion arriba).
    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.spa_fallback.arn
    }

    compress = true
  }

  # --- Comportamiento /api/*: API dinamica hacia el ALB, sin cache ---
  ordered_cache_behavior {
    path_pattern           = "/api/*"
    target_origin_id       = local.alb_origin_id
    viewer_protocol_policy = "redirect-to-https"

    allowed_methods = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods  = ["GET", "HEAD"]

    # Managed policy "CachingDisabled" — respuestas dinamicas con Authorization.
    cache_policy_id = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"

    # Managed policy "AllViewerExceptHostHeader" — reenvia Authorization,
    # query strings y cookies al origin sin romper el Host del ALB.
    origin_request_policy_id = "b689b0a8-53d0-40ab-baf2-68738e2966ac"

    # Quita el prefijo /api antes de llegar al ALB.
    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.strip_api_prefix.arn
    }

    compress = true
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.cloudfront.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  tags = { Name = "${var.project_name}-cloudfront" }
}
