# ---------------------------------------------------------------------------
# RDS PostgreSQL — reemplaza el H2 in-memory de la demo por una base
# persistente, Multi-AZ, con réplicas de lectura para separar tráfico de
# reportes/insights del tráfico transaccional (orders/questions).
# ---------------------------------------------------------------------------

resource "aws_db_subnet_group" "main" {
  name       = "${var.project_name}-db-subnet-group"
  subnet_ids = aws_subnet.private_data[*].id

  tags = { Name = "${var.project_name}-db-subnet-group" }
}

resource "random_password" "db_master" {
  length  = 24
  special = false
}

resource "aws_db_instance" "primary" {
  identifier     = "${var.project_name}-db"
  engine         = "postgres"
  engine_version = "16.3"
  instance_class = var.db_instance_class

  allocated_storage     = 100
  max_allocated_storage = 500 # autoscaling de storage ante crecimiento inesperado
  storage_type          = "gp3"
  storage_encrypted     = true

  db_name  = var.db_name
  username = "app_user"
  password = random_password.db_master.result

  # Multi-AZ: failover automático a una réplica sincrónica en otra AZ
  # ante la caída de la instancia primaria, sin intervención manual.
  multi_az = true

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  backup_retention_period = 7
  backup_window           = "03:00-04:00"
  maintenance_window      = "mon:04:30-mon:05:30"

  deletion_protection       = true
  skip_final_snapshot       = false
  final_snapshot_identifier = "${var.project_name}-db-final-snapshot"

  performance_insights_enabled = true

  tags = { Name = "${var.project_name}-db-primary" }
}

# --- Réplicas de lectura: absorben el tráfico de /insights y reportes pesados ---
resource "aws_db_instance" "read_replica" {
  count = var.db_read_replica_count

  identifier          = "${var.project_name}-db-replica-${count.index}"
  replicate_source_db = aws_db_instance.primary.identifier
  instance_class      = var.db_instance_class

  vpc_security_group_ids = [aws_security_group.rds.id]
  storage_encrypted      = true

  performance_insights_enabled = true

  tags = { Name = "${var.project_name}-db-replica-${count.index}" }
}
