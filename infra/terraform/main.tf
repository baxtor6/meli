terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    helm = {
      source = "hashicorp/helm"
      # Fijado a la serie 2.x: la config de este modulo (bloque anidado
      # `kubernetes {}` en el provider y bloques `set {}` en los helm_release)
      # usa la sintaxis del provider helm v2. El provider v3 cambio ese esquema
      # (`kubernetes = {}` y `set = [{...}]`), asi que se acota el constraint
      # para no resolver v3 por error.
      version = "~> 2.17"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.27"
    }
  }

  # NOTA: Para esta prueba usamos backend LOCAL (el state se guarda en disco,
  # en terraform.tfstate dentro de esta carpeta). Es lo más simple para evaluar
  # el código sin depender de recursos previos en AWS.
  #
  # En un entorno de PRODUCCIÓN esto NO es recomendable: el state debe ir remoto
  # (S3) con bloqueo de estado (lock) para permitir colaboración y evitar la
  # corrupción del state por ejecuciones concurrentes. La config remota sería:
  #
  #   backend "s3" {
  #     bucket       = "seller-dashboard-terraform-state"
  #     key          = "production/terraform.tfstate"
  #     region       = "us-east-1"
  #     use_lockfile = true   # lock nativo de S3 (Terraform >= 1.10),
  #                           # reemplaza a la ya deprecada dynamodb_table
  #     encrypt      = true
  #   }
  backend "local" {
    path = "terraform.tfstate"
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = var.tags
  }
}

# CloudFront y su certificado ACM asociado DEBEN vivir en us-east-1,
# independientemente de la region donde este el resto de la infra.
# Este provider aliased se usa solo para esos recursos (ver cloudfront.tf).
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  default_tags {
    tags = var.tags
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}

# Token efimero para autenticar los providers kubernetes/helm contra el
# cluster EKS creado en eks.tf.
data "aws_eks_cluster_auth" "main" {
  name = aws_eks_cluster.main.name
}

provider "kubernetes" {
  host                   = aws_eks_cluster.main.endpoint
  cluster_ca_certificate = base64decode(aws_eks_cluster.main.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.main.token
}

provider "helm" {
  kubernetes {
    host                   = aws_eks_cluster.main.endpoint
    cluster_ca_certificate = base64decode(aws_eks_cluster.main.certificate_authority[0].data)
    token                  = data.aws_eks_cluster_auth.main.token
  }
}
