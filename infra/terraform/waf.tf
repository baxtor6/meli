# ---------------------------------------------------------------------------
# AWS WAFv2 — primera linea de defensa de la API expuesta a internet.
#
# Se definen DOS Web ACLs porque WAFv2 exige que el "scope" coincida con el
# recurso protegido:
#   - scope = CLOUDFRONT  -> debe crearse en us-east-1, se asocia a la
#     distribucion de CloudFront (edge, filtra lo antes posible).
#   - scope = REGIONAL    -> vive en la region de la infra, se asocia al ALB
#     (defensa en profundidad: aunque alguien llegue directo al ALB).
#
# Reglas incluidas en ambos:
#   1. Rate-limiting por IP  -> absorbe picos anomalos/bots antes de los pods,
#      critico para el escenario de 10,000 req/s con picos tipo Black Friday.
#   2. AWS Managed Rules     -> Common (XSS/LFI/RFI), SQLi, Known Bad Inputs,
#      IP Reputation List. Cubren el OWASP Top 10 sin mantener firmas a mano.
#
# NOTA (challenge): esto es ilustrativo y no se despliega; los valores de
# rate-limit y las reglas son puntos de partida razonables, no tuneados.
# ---------------------------------------------------------------------------

# =========================================================================
# WAF para CloudFront (edge) — DEBE estar en us-east-1
# =========================================================================
resource "aws_wafv2_web_acl" "cloudfront" {
  provider = aws.us_east_1

  name        = "${var.project_name}-cloudfront-waf"
  description = "WAF edge asociado a CloudFront"
  scope       = "CLOUDFRONT"

  default_action {
    allow {}
  }

  # --- Regla 1: rate-limiting por IP ---
  rule {
    name     = "rate-limit-per-ip"
    priority = 1

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = var.waf_rate_limit_per_5min
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.project_name}-cf-rate-limit"
      sampled_requests_enabled   = true
    }
  }

  # --- Regla 2: AWS Managed - Common Rule Set (XSS, LFI, etc.) ---
  rule {
    name     = "aws-common"
    priority = 2

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.project_name}-cf-common"
      sampled_requests_enabled   = true
    }
  }

  # --- Regla 3: AWS Managed - SQL Injection ---
  rule {
    name     = "aws-sqli"
    priority = 3

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesSQLiRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.project_name}-cf-sqli"
      sampled_requests_enabled   = true
    }
  }

  # --- Regla 4: AWS Managed - Known Bad Inputs ---
  rule {
    name     = "aws-bad-inputs"
    priority = 4

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.project_name}-cf-bad-inputs"
      sampled_requests_enabled   = true
    }
  }

  # --- Regla 5: AWS Managed - IP Reputation List ---
  rule {
    name     = "aws-ip-reputation"
    priority = 5

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesAmazonIpReputationList"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.project_name}-cf-ip-rep"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.project_name}-cloudfront-waf"
    sampled_requests_enabled   = true
  }

  tags = { Name = "${var.project_name}-cloudfront-waf" }
}

# =========================================================================
# WAF para el ALB (regional) — defensa en profundidad
# =========================================================================
resource "aws_wafv2_web_acl" "alb" {
  name        = "${var.project_name}-alb-waf"
  description = "WAF regional asociado al ALB"
  scope       = "REGIONAL"

  default_action {
    allow {}
  }

  rule {
    name     = "rate-limit-per-ip"
    priority = 1

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = var.waf_rate_limit_per_5min
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.project_name}-alb-rate-limit"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "aws-common"
    priority = 2

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.project_name}-alb-common"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "aws-sqli"
    priority = 3

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesSQLiRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.project_name}-alb-sqli"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "aws-bad-inputs"
    priority = 4

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.project_name}-alb-bad-inputs"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "aws-ip-reputation"
    priority = 5

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesAmazonIpReputationList"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.project_name}-alb-ip-rep"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.project_name}-alb-waf"
    sampled_requests_enabled   = true
  }

  tags = { Name = "${var.project_name}-alb-waf" }
}

# Asociacion del WAF regional al ALB:
# En Opcion A el ALB lo crea el LB Controller, asi que la asociacion se hace
# via la annotation `alb.ingress.kubernetes.io/wafv2-acl-arn` del Ingress
# (ver k8s/base/ingress.yaml), usando el ARN expuesto por el output
# `waf_alb_acl_arn`. No se usa aws_wafv2_web_acl_association aqui porque el
# recurso aws_lb no existe en el state de Terraform en esta opcion.
# (El WAF de CloudFront si se asocia via web_acl_id de la distribucion.)
