# ---------------------------------------------------------------------------
# Security Groups — principio de menor privilegio entre capas
# ---------------------------------------------------------------------------

# --- ALB: solo recibe 443/80 desde internet ---
resource "aws_security_group" "alb" {
  name        = "${var.project_name}-alb-sg"
  description = "Trafico publico HTTPS/HTTP hacia el ALB"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTPS publico"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTP publico (redirige a 443)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-alb-sg" }
}

# --- EKS nodes: solo acepta trafico del ALB (puerto de la app) y entre si (control plane) ---
resource "aws_security_group" "eks_nodes" {
  name        = "${var.project_name}-eks-nodes-sg"
  description = "Trafico desde el ALB hacia los pods del API"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "Trafico de la app (8080) solo desde el ALB"
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  ingress {
    description = "Comunicacion interna del cluster (control plane <-> nodos, kubelet, webhooks)"
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    self        = true
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name                                        = "${var.project_name}-eks-nodes-sg"
    "kubernetes.io/cluster/${var.project_name}" = "owned"
  }
}

# --- RDS: solo acepta 5432 desde los nodos de EKS ---
resource "aws_security_group" "rds" {
  name        = "${var.project_name}-rds-sg"
  description = "Postgres accesible unicamente desde los pods del API"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "Postgres desde nodos EKS"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.eks_nodes.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-rds-sg" }
}

# --- ElastiCache Redis: solo acepta 6379 desde los nodos de EKS ---
resource "aws_security_group" "redis" {
  name        = "${var.project_name}-redis-sg"
  description = "Redis accesible unicamente desde los pods del API"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "Redis desde nodos EKS"
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [aws_security_group.eks_nodes.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-redis-sg" }
}
