# ---------------------------------------------------------------------------
# Secrets Manager — credenciales nunca en variables de entorno planas ni en
# ConfigMaps; los pods las leen en runtime vía IRSA (ver eks.tf).
# ---------------------------------------------------------------------------

resource "aws_secretsmanager_secret" "db_credentials" {
  name                    = "${var.project_name}/db-credentials"
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "db_credentials" {
  secret_id = aws_secretsmanager_secret.db_credentials.id
  secret_string = jsonencode({
    username = aws_db_instance.primary.username
    password = random_password.db_master.result
    host     = aws_db_instance.primary.address
    port     = aws_db_instance.primary.port
    dbname   = var.db_name
  })
}

resource "random_password" "jwt_secret" {
  length  = 64
  special = true
}

resource "aws_secretsmanager_secret" "jwt_secret" {
  name                    = "${var.project_name}/jwt-secret"
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "jwt_secret" {
  secret_id     = aws_secretsmanager_secret.jwt_secret.id
  secret_string = random_password.jwt_secret.result
}
