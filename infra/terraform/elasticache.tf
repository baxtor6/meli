# ---------------------------------------------------------------------------
# ElastiCache Redis — reemplaza el Caffeine cache local (in-memory, por pod)
# por una cache distribuida compartida entre todos los pods del API.
# Usos: cache de /insights (TTL corto), rate-limiting por usuario/IP,
# y almacenamiento de sesiones si se requiere invalidar JWT (deny-list).
# ---------------------------------------------------------------------------

resource "aws_elasticache_subnet_group" "main" {
  name       = "${var.project_name}-redis-subnet-group"
  subnet_ids = aws_subnet.private_data[*].id
}

resource "aws_elasticache_replication_group" "main" {
  replication_group_id = "${var.project_name}-redis"
  description          = "Cache distribuida para insights y rate-limiting"

  engine         = "redis"
  engine_version = "7.1"
  node_type      = var.redis_node_type
  port           = 6379

  num_node_groups         = var.redis_shard_count
  replicas_per_node_group = 1 # 1 réplica por shard para HA de lectura

  automatic_failover_enabled = true
  multi_az_enabled           = true

  subnet_group_name  = aws_elasticache_subnet_group.main.name
  security_group_ids = [aws_security_group.redis.id]

  at_rest_encryption_enabled = true
  transit_encryption_enabled = true

  snapshot_retention_limit = 3
  snapshot_window          = "05:00-06:00"

  tags = { Name = "${var.project_name}-redis" }
}
