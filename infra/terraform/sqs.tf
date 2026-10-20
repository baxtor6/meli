# ---------------------------------------------------------------------------
# SQS — desacopla el envío de notificaciones (email/alertas de preguntas
# HIGH/CRITICAL) del hilo de request principal. El API publica el mensaje
# y responde de inmediato; un worker consume la cola de forma asíncrona.
# ---------------------------------------------------------------------------

resource "aws_sqs_queue" "notifications_dlq" {
  name                      = "${var.project_name}-notifications-dlq"
  message_retention_seconds = 1209600 # 14 dias, tiempo para investigar fallos
}

resource "aws_sqs_queue" "notifications" {
  name                       = "${var.project_name}-notifications"
  visibility_timeout_seconds = 30
  message_retention_seconds  = 86400

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.notifications_dlq.arn
    maxReceiveCount     = 5
  })

  tags = { Name = "${var.project_name}-notifications" }
}
