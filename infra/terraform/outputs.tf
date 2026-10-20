output "alb_hostname" {
  description = "Hostname estable del ALB (lo publica ExternalDNS desde el Ingress). Es el origin de CloudFront."
  value       = var.domain_name
}

output "alb_security_group_id" {
  description = "SG del ALB — el pipeline lo inyecta en la annotation security-groups del Ingress"
  value       = aws_security_group.alb.id
}

output "alb_acm_certificate_arn" {
  description = "ARN del certificado ACM del ALB — annotation certificate-arn del Ingress"
  value       = aws_acm_certificate.alb.arn
}

output "alb_logs_bucket" {
  description = "Bucket S3 de access logs del ALB — annotation load-balancer-attributes del Ingress"
  value       = aws_s3_bucket.alb_logs.bucket
}

output "frontend_bucket" {
  description = "Bucket S3 de la SPA — el pipeline hace `aws s3 sync dist/` aqui (secret FRONTEND_BUCKET)"
  value       = aws_s3_bucket.frontend.bucket
}

output "eks_cluster_endpoint" {
  description = "Endpoint del plano de control de EKS"
  value       = aws_eks_cluster.main.endpoint
}

output "eks_cluster_name" {
  description = "Nombre del cluster EKS (usar con aws eks update-kubeconfig)"
  value       = aws_eks_cluster.main.name
}

output "rds_primary_endpoint" {
  description = "Endpoint de escritura (primary) de PostgreSQL"
  value       = aws_db_instance.primary.address
  sensitive   = true
}

output "rds_read_replica_endpoints" {
  description = "Endpoints de solo lectura para /insights y reportes"
  value       = aws_db_instance.read_replica[*].address
  sensitive   = true
}

output "redis_primary_endpoint" {
  description = "Endpoint de configuracion del cluster Redis"
  value       = aws_elasticache_replication_group.main.configuration_endpoint_address
}

output "notifications_queue_url" {
  description = "URL de la cola SQS de notificaciones asincronas"
  value       = aws_sqs_queue.notifications.id
}

output "db_credentials_secret_arn" {
  description = "ARN del secreto con credenciales de la base de datos"
  value       = aws_secretsmanager_secret.db_credentials.arn
}

output "jwt_secret_arn" {
  description = "ARN del secreto con la clave de firma JWT"
  value       = aws_secretsmanager_secret.jwt_secret.arn
}

output "cloudfront_domain_name" {
  description = "Dominio *.cloudfront.net de la distribucion (target del registro ALIAS del API)"
  value       = aws_cloudfront_distribution.api.domain_name
}

output "cloudfront_distribution_id" {
  description = "ID de la distribucion de CloudFront (para invalidaciones de cache)"
  value       = aws_cloudfront_distribution.api.id
}

output "route53_zone_id" {
  description = "ID de la hosted zone de Route53"
  value       = aws_route53_zone.main.zone_id
}

output "route53_name_servers" {
  description = "Name servers de la zona — delegar aqui el dominio en el registrador"
  value       = aws_route53_zone.main.name_servers
}

output "public_app_url" {
  description = "URL publica de la SPA (CloudFront -> S3). Raiz del dominio."
  value       = "https://${var.cdn_domain_name}"
}

output "public_api_url" {
  description = "URL publica del API (CloudFront -> WAF -> ALB), bajo el prefijo /api"
  value       = "https://${var.cdn_domain_name}/api"
}

output "waf_cloudfront_acl_arn" {
  description = "ARN del Web ACL de WAF asociado a CloudFront"
  value       = aws_wafv2_web_acl.cloudfront.arn
}

output "waf_alb_acl_arn" {
  description = "ARN del Web ACL de WAF asociado al ALB"
  value       = aws_wafv2_web_acl.alb.arn
}
