variable "project_name" {
  description = "Nombre base usado como prefijo en todos los recursos"
  type        = string
  default     = "seller-dashboard"
}

variable "environment" {
  description = "Entorno de despliegue (staging/production)"
  type        = string
  default     = "production"
}

variable "aws_region" {
  description = "Región de AWS donde se despliega la infraestructura"
  type        = string
  default     = "us-east-1"
}

variable "vpc_cidr" {
  description = "CIDR block de la VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "Zonas de disponibilidad a usar (mínimo 3 para alta disponibilidad real)"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b", "us-east-1c"]
}

variable "eks_node_min_size" {
  description = "Mínimo de nodos EKS (2 por AZ = 6 para tolerar caída de una zona)"
  type        = number
  default     = 6
}

variable "eks_node_max_size" {
  description = "Máximo de nodos EKS para absorber picos de 10x tráfico (Black Friday)"
  type        = number
  default     = 24
}

variable "eks_node_instance_types" {
  description = "Tipos de instancia para los nodos del cluster"
  type        = list(string)
  default     = ["m6i.xlarge"]
}

variable "db_instance_class" {
  description = "Clase de instancia RDS para el primary"
  type        = string
  default     = "db.r6g.xlarge"
}

variable "db_read_replica_count" {
  description = "Cantidad de réplicas de lectura (para endpoints de insights/reportes)"
  type        = number
  default     = 2
}

variable "db_name" {
  description = "Nombre de la base de datos de aplicación"
  type        = string
  default     = "seller_dashboard"
}

variable "redis_node_type" {
  description = "Tipo de nodo para el cluster de Redis (cache de insights + rate-limit)"
  type        = string
  default     = "cache.r6g.large"
}

variable "redis_shard_count" {
  description = "Cantidad de shards del cluster Redis"
  type        = number
  default     = 3
}

variable "api_container_image" {
  description = "Imagen de contenedor del API (tag inmutable = SHA del commit, provisto por el pipeline CI/CD)"
  type        = string
  default     = "ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com/seller-dashboard-api:latest"
}

variable "api_min_replicas" {
  description = "Mínimo de pods del API (HPA) — 2 por AZ para resiliencia"
  type        = number
  default     = 6
}

variable "api_max_replicas" {
  description = "Máximo de pods del API (HPA) — dimensionado para ~170 req/s por pod @ 10,000 req/s"
  type        = number
  default     = 60
}

variable "root_domain" {
  description = "Dominio raiz de la hosted zone de Route53 (placeholder para el challenge)"
  type        = string
  default     = "seller-dashboard.example.com"
}

variable "domain_name" {
  description = "FQDN del ALB (origin / acceso directo). Usado para el certificado ACM regional del ALB y como hostname estable que ExternalDNS asigna al ALB creado por el LB Controller"
  type        = string
  default     = "origin.seller-dashboard.example.com"
}

variable "cdn_domain_name" {
  description = "FQDN publico del API servido por CloudFront. Usado para el certificado ACM en us-east-1"
  type        = string
  default     = "api.seller-dashboard.example.com"
}

variable "waf_rate_limit_per_5min" {
  description = "Limite de requests por IP en ventana de 5 min (WAF rate-based rule). 2000 = ~6.6 req/s por IP sostenido"
  type        = number
  default     = 2000
}

variable "eks_addon_versions" {
  description = "Versiones de los EKS managed add-ons (placeholders; fijar segun la version del cluster)"
  type        = map(string)
  default = {
    "vpc-cni"    = "v1.18.1-eksbuild.3"
    "coredns"    = "v1.11.1-eksbuild.6"
    "kube-proxy" = "v1.29.3-eksbuild.2"
  }
}

variable "helm_chart_versions" {
  description = "Versiones de los charts Helm de los controllers (placeholders; fijar y probar en staging)"
  type        = map(string)
  default = {
    "aws-load-balancer-controller"          = "1.7.2"
    "cluster-autoscaler"                    = "9.37.0"
    "metrics-server"                        = "3.12.1"
    "external-dns"                          = "1.14.5"
    "secrets-store-csi-driver"              = "1.4.4"
    "secrets-store-csi-driver-provider-aws" = "0.3.9"
  }
}

variable "tags" {
  description = "Tags comunes aplicados a todos los recursos"
  type        = map(string)
  default = {
    Project   = "seller-dashboard"
    ManagedBy = "terraform"
  }
}
