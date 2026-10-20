# DevOps Round II — Seller Dashboard API en producción (10,000 req/s)

> Ver el diagrama en [architecture.drawio](./architecture.drawio).
> Los templates de IaC están en [terraform/](./terraform/).

## Índice

1. [Contexto y supuestos](#contexto-y-supuestos)
2. [Arquitectura de solución](#arquitectura-de-solución)
3. [Justificación de cada componente](#justificación-de-cada-componente)
4. [Decisiones de diseño y alternativas descartadas](#decisiones-de-diseño-y-alternativas-descartadas)

> El **pipeline CI/CD**, la **infraestructura como código (IaC)** y la **validación contra los requerimientos del challenge** están documentados en el [`README.md`](../README.md) del repositorio.

---

## Contexto y supuestos

El challenge original (Seller Dashboard: Orders & Questions) es una API Spring Boot + frontend React. Para esta Parte 2 (DevOps) se asume:

- **Cloud objetivo**: AWS.
- **Carga objetivo**: 10,000 requests/segundo sostenidos, con picos de hasta 10x (escenario "Black Friday" mencionado en el problem statement).
- **Base de datos**: en producción real, H2 (usado en el challenge original solo para demo/seed) se reemplaza por **PostgreSQL gestionado** (RDS), ya que H2 en memoria no es apto para múltiples réplicas ni persistencia real.
- **Contenedores sobre Kubernetes (EKS)**: se elige K8s en vez de un PaaS más simple (ej. ECS/App Runner) porque ya es el estándar de facto para cargas que requieren autoscaling fino, multi-AZ y portabilidad entre clouds — y porque el planteamiento del ejercicio sugiere que el sistema seguirá creciendo en servicios: notificaciones Slack/SMS, crecimiento de equipo.

## Arquitectura de solución

Ver diagrama completo en [architecture.drawio](./architecture.drawio). Resumen de capas (de afuera hacia adentro):

```
Internet → DNS → CDN (CloudFront) ─┬─ /*      → S3 (SPA estática, cache alto)
                                   └─ /api/*  → WAF → ALB → Ingress → API Pods (HPA) → Cache / DB primary+réplicas
                                                                              ↘ Cola async → Workers de notificación
         Observabilidad (métricas/logs) transversal a todas las capas
```

Una sola distribución de CloudFront con **dos orígenes**, repartidos por path: el comportamiento por defecto sirve la **SPA estática desde S3** (bucket privado vía OAC) y el comportamiento `/api/*` reenvía al **ALB** (API dinámica). El frontend no pasa por EKS: solo el backend corre en los pods.

## Justificación de cada componente

### 1. Edge / Perimeter

> Implementado en IaC: [route53.tf](./terraform/route53.tf), [cloudfront.tf](./terraform/cloudfront.tf), [s3_frontend.tf](./terraform/s3_frontend.tf), [waf.tf](./terraform/waf.tf) y [acm.tf](./terraform/acm.tf).

| Componente | Por qué |
|---|---|
| **DNS con routing por salud** (Route53) | Permite failover automático entre regiones si una zona cae completa, y resolución de latencia mínima (geo-routing) para sellers en distintas regiones. En el Terraform se crea la hosted zone y el ALIAS API→CloudFront; el registro del ALB lo publica ExternalDNS desde el Ingress (una sola fuente de verdad). El failover multi-región se deja indicado como extensión. |
| **CDN** (CloudFront) | Una distribución con **dos orígenes** repartidos por path. **`/*` → S3** (default behavior): el frontend es una SPA estática (Vite build), servirla desde S3+CDN descarga al backend y mejora latencia; bucket privado accedido solo por CloudFront vía **OAC**, con `CachingOptimized` (assets con hash). **`/api/*` → ALB** (ordered behavior): respuestas dinámicas con `Authorization`, por eso `CachingDisabled`; una CloudFront Function quita el prefijo `/api` para que el backend siga respondiendo en `/...` sin cambios. **Fallback SPA**: otra CloudFront Function reescribe las rutas de navegación (sin extensión) a `/index.html`, solo en el behavior de S3 — no se usa `custom_error_response` porque aplica a toda la distribución y convertiría los 403/404 legítimos de la API en `index.html`. Para toda la API, CloudFront además aporta TLS en el edge, absorción de picos y DDoS (Shield Standard). |
| **WAF** (AWS WAF) | Primera línea de defensa contra inyección SQL, XSS (relevante porque el challenge ya identificó que las preguntas de compradores son texto libre potencialmente malicioso) y bots. Incluye **rate-limiting por IP**, crítico para absorber picos anómalos antes de que lleguen a los pods. Se despliega en dos scopes: uno en el edge (CloudFront) y otro regional en el ALB (defensa en profundidad), ambos con AWS Managed Rules (Common/SQLi/Bad Inputs/IP Reputation). |
| **ACM (TLS gestionado)** | Certificados con renovación automática validados por DNS. Se emiten dos: uno regional para el ALB y otro en `us-east-1` para CloudFront (requisito de AWS para distribuciones de edge). |

### 2. Capa de aplicación (VPC — subnets públicas/privadas)

| Componente | Por qué |
|---|---|
| **Application Load Balancer (L7)** | Termina TLS (certificados gestionados vía ACM, rotación automática), hace health-checks activos contra `/actuator/health` y balancea entre AZs. Un NLB (L4) sería más rápido pero perderíamos routing por path/host, útil si se separan APIs en el futuro. **Propiedad**: el ALB lo crea el AWS Load Balancer Controller a partir del Ingress (una sola fuente de verdad), no Terraform; con `target-type: ip` registra los pods directamente, ideal con HPA. |
| **Kubernetes (EKS)** | Orquesta los pods del API con **Horizontal Pod Autoscaler (HPA)** basado en utilización de CPU (vía metrics-server). Rango 6–60 réplicas: el mínimo (6, 2 por AZ) garantiza resiliencia ante la caída de una zona completa; el máximo (60) cubre el pico de 10,000 req/s asumiendo ~170 req/s por pod. |
| **Add-ons / controllers del cluster** | Instalados vía Helm con IRSA (ver `eks_addons.tf`): **AWS LB Controller** (crea el ALB desde el Ingress), **Cluster Autoscaler** (escala los nodos del node group, complementando al HPA que escala pods), **metrics-server** (métricas de CPU que consume el HPA), **ExternalDNS** (registro Route53 del ALB) y **Secrets Store CSI** (monta los secretos de Secrets Manager en los pods). |
| **Startup/Readiness/Liveness probes** sobre `/actuator/health` | Definidas en [`k8s/base/deployment.yaml`](./k8s/base/deployment.yaml): la *startup* da ~150s de gracia a la JVM; la *readiness* saca el pod del balanceo sin reiniciarlo (evita 5xx en arranques/picos); la *liveness* reinicia el contenedor si queda colgado. El endpoint lo expone Actuator vía `application.properties` (`management.endpoints.web.exposure.include=health,...`). *Nota*: el backend de este repo es un esqueleto sin Spring Security, así que `/actuator/health` queda abierto por defecto; en el proyecto completo de la Parte 1 se añadiría `permitAll()` sobre ese path en el `SecurityConfig`. |
| **Pod Disruption Budget + anti-affinity** | Garantiza que actualizaciones/rolling restarts no tiren más de N pods a la vez, y que las réplicas se distribuyan entre AZs (no todas en la misma zona). |
| **Redis Cluster** (ElastiCache) | El servicio `InsightsService` ya usa caché con TTL (Caffeine en memoria del proceso). En un despliegue multi-pod, un caché **en memoria de cada pod se invalida de forma inconsistente** entre réplicas. Redis centralizado resuelve esto: todos los pods comparten el mismo caché, reduciendo carga repetida sobre la base de datos. También almacena contadores de rate-limiting distribuido. |

> **¿Por qué 3 Availability Zones y no 2?** Dos razones:
> - **Capacidad perdida ante la caída de una AZ**: con 2 AZs, perder una elimina el **50%** de la capacidad, obligando a sobreaprovisionar al doble para no degradar el servicio. Con 3 AZs, la caída de una solo cuesta el **33%** y las otras dos absorben la carga con mucho menos headroom. Con el HPA mínimo de 6 pods: 3 AZs → quedan 4 de 6 vivos (66%); 2 AZs → quedan 3 de 6 (50%). A 10.000 req/s, perder un tercio es mucho más manejable que perder la mitad.
> - **Quórum**: los sistemas de consenso (etcd/control plane de EKS, y cualquier sistema basado en mayoría que se agregue luego: Kafka, etc.) necesitan un número **impar** para tolerar fallos sin empatar. Con 3 nodos sobreviven perdiendo 1 (mayoría 2 de 3); con 2, la caída de 1 rompe el quórum.
>
> El costo incremental de 3 vs. 2 es marginal (un NAT Gateway extra, tres subnets por capa, algo más de tráfico cross-AZ) y **no** implica triplicar cómputo: los pods totales son los mismos, solo mejor distribuidos. Además es el estándar de AWS (casi todas las regiones tienen 3+ AZs) y lo que asumen RDS Multi-AZ, ElastiCache y los balanceadores.

### 3. Capa de datos

| Componente | Por qué |
|---|---|
| **PostgreSQL gestionado (RDS Multi-AZ)** | Reemplaza el H2 en memoria del challenge original. Multi-AZ da failover automático (<60s) sin intervención manual ante caída del nodo primario. |
| **Read Replicas (x2)** | Los endpoints de `/insights` (agregaciones SQL pesadas) y búsquedas paginadas de `/orders` son de solo lectura — dirigirlos a réplicas libera capacidad de escritura en el primary para checkout/creación de órdenes, que son operaciones más sensibles a latencia. |
| **Subnets de datos aisladas, sin ruta a internet** | Ni siquiera el NAT Gateway debería permitir salida directa desde esta subnet — solo tráfico desde los pods del API vía Security Groups con least-privilege. |

### 4. Procesamiento asíncrono

| Componente | Por qué |
|---|---|
| **Cola de mensajes (SQS)** | El sistema de notificaciones del challenge (`NotificationService` + `NotificationChannel`) ya está diseñado para ser extensible (email hoy, Slack/SMS después). En producción, publicar un evento a una cola — en vez de llamar directamente a proveedores externos (SendGrid, Twilio, Slack API) de forma síncrona — evita que una pregunta HIGH/CRITICAL bloquee el request del seller si el proveedor de notificaciones está lento o caído. |
| **Workers independientes** | Escalan de forma separada del API (distinta carga: ráfagas de notificaciones vs. tráfico constante de lectura/escritura), y permiten reintentos con backoff sin afectar la disponibilidad del API principal. |

### 5. Seguridad transversal

| Componente | Por qué |
|---|---|
| **Secrets Manager** | El `application.properties` actual tiene `app.jwt.secret` como placeholder de demo — en producción debe inyectarse en runtime desde un gestor de secretos, nunca en el manifiesto ni en la imagen. |
| **IAM Roles de mínimo privilegio (IRSA en EKS)** | Cada pod asume un rol con permisos acotados (ej. solo lectura/escritura a su propia tabla en RDS, solo publish a su cola SQS) — nunca credenciales estáticas de AWS dentro del contenedor. |
| **Network Policies de Kubernetes** | Restringen qué pods pueden hablarse entre sí (ej. solo el API puede hablar con Redis/RDS; los workers de notificación no tienen acceso directo a la base de datos de órdenes). |

### 6. Observabilidad (capa recomendada — fuera del alcance mínimo del challenge)

> El challenge no pide observabilidad explícitamente; se incluye como capa recomendada porque refuerza la resiliencia operativa (relevante por el incidente de Black Friday).

| Componente | Por qué |
|---|---|
| **Métricas** (CloudWatch Container Insights) | Métricas del cluster y de la app (`/actuator/metrics`, ya expuesto): latencia, tasa de error, saturación del pool de conexiones a DB. El autoscaling del HPA se basa en CPU vía metrics-server. |
| **Logging centralizado** (CloudWatch Logs) | El proyecto ya usa logging estructurado con MDC (`requestId`, `sellerId`) vía `JwtAuthFilter` — en producción estos logs se agregan centralizadamente para poder correlacionar un request completo entre pods. |
| **Alerting proactivo** (CloudWatch Alarms → SNS) | Alarmas de CloudWatch sobre tasa de error > umbral, latencia p99 > umbral y uso de CPU/memoria del HPA al límite; se notifican vía un topic de SNS (email/SMS, o webhook a chat) — exactamente lo que faltaba según el enunciado ("el equipo no tenía idea de qué pasaba por horas"). |

> **Extensión futura — autoscaling por requests/segundo**: el HPA actual escala solo por **CPU** (vía metrics-server), que es suficiente para el alcance del challenge. Si se quisiera escalar directamente por **requests/segundo** (una señal más precisa para una API I/O-bound que la CPU), habría que incorporar lo siguiente al diseño base:
> - **Prometheus** (ej. Amazon Managed Service for Prometheus o kube-prometheus-stack) para scrapear `/actuator/prometheus` y almacenar la serie `http_requests_per_second`.
> - **Prometheus Adapter** (chart Helm, con su IRSA) para exponer esa métrica a la Custom Metrics API de Kubernetes.
> - En el **HPA**, añadir un segundo target de tipo `Pods` sobre `http_requests_per_second` (ej. ~170 req/s por pod) junto al de CPU.
> - **Grafana** (ej. Amazon Managed Grafana) opcional, para dashboards sobre esas métricas.
>
> Se dejó fuera para no sumar un stack de observabilidad completo que el challenge no pide; la ruta de implementación queda documentada arriba.

---

## Decisiones de diseño y alternativas descartadas

### CloudFront al frente, en vez de ir directo al ALB o usar API Gateway

| Opción | Encaja cuando | Por qué (no) aquí |
|---|---|---|
| **CloudFront → WAF → ALB → EKS** ✓ | API pública de alto volumen con una SPA asociada | TLS termina en el edge (menor latencia por handshake cerca del usuario); DDoS protection vía AWS Shield Standard; la SPA estática se sirve cacheada desde el edge, descargando a los pods; WAF filtra en el borde antes de consumir recursos de la VPC. |
| **Directo al ALB** | API interna sin SPA ni necesidad de edge | Se pierde el TLS en el edge, la caché de la SPA y la primera capa anti-DDoS; el ALB recibe todo el tráfico (incluidos assets estáticos) en una sola región. |
| **API Gateway** | Serverless (Lambda), API keys / planes de uso, developer portal, bajo volumen o picos esporádicos | A 10.000 req/s sostenidos (~864 M req/día) el costo por-request se dispara frente al ALB; además duplica funciones que ya resuelve el stack (JWT en Spring Security, rate-limit en WAF+Redis, routing en el Ingress). |

> Costo honesto de CloudFront: agrega un salto de red y algo de operación (header `X-Origin-Verify` para que el ALB solo acepte tráfico vía el edge, invalidaciones de caché). Se justifica por el perfil de carga; para una API puramente interna no valdría la pena.

### Una sola distribución de CloudFront (split por path), en vez de dos

La SPA (frontend estático en S3) y la API (backend en EKS) se sirven desde **una única distribución de CloudFront bajo un mismo dominio**, repartiendo el tráfico por path: `/*` → S3 (SPA) y `/api/*` → ALB. La alternativa sería **dos distribuciones** con subdominios separados (`app.*` para la SPA y `api.*` para la API).

| | 1 distribución, split por path (`/api/*`) ✓ | 2 distribuciones, subdominios (`app.*` / `api.*`) |
|---|---|---|
| **Enrutado** | CloudFront enruta por path dentro de la distribución: default behavior → S3, behavior `/api/*` → ALB | Cada distribución tiene su propio origin y su propio dominio |
| **CORS** | **No hace falta**: SPA y API comparten protocolo + dominio + puerto (same-origin) | El browser los ve como dominios distintos → **CORS obligatorio** (headers `Access-Control-*` en el backend) |
| **Operación** | Un dominio, un certificado, una distribución que operar | Dos distribuciones, dos configs, normalmente dos certificados |
| **Cookies de sesión** | Funcionan sin configuración cross-domain | Requieren cuidado extra (dominio de cookie, `SameSite`) |
| **Cuándo conviene** | SPA con **su propia** API detrás (este caso) | La API es un **producto independiente** (otro equipo/versionado, o clientes externos que consumen solo la API) |

Se elige **una distribución** porque la SPA y su API son parte del mismo producto: el same-origin elimina CORS y simplifica la operación (un dominio, un cert, un punto de entrada). La única implicación es que la SPA llama al backend bajo el prefijo `/api` (ej. `fetch('/api/orders')`); una CloudFront Function quita ese prefijo antes del ALB para que el backend siga respondiendo en `/...` sin cambios.

> **Por qué la llamada SPA→API pasa por CloudFront.** Una SPA se **descarga** una vez (desde el edge), pero luego **se ejecuta en el browser del usuario**. Cuando hace `fetch('/api/...')`, esa petición sale desde la máquina del usuario, así que entra a AWS por el único punto de entrada público: CloudFront. No es un desvío desperdiciado — en ese mismo salto aporta TLS en el edge, WAF y Shield (DDoS) para la ruta `/api/*`, con `CachingDisabled` porque la API es dinámica. El tráfico **interno** (pod↔pod, backend↔RDS/Redis/SQS) no pasa por CloudFront: viaja dentro de la VPC.

### ALB (L7) en vez de NLB (L4)

| | ALB (Application LB, capa 7) ✓ | NLB (Network LB, capa 4) |
|---|---|---|
| **Nivel** | HTTP/HTTPS: entiende rutas, hosts, headers | TCP/UDP: solo IP:puerto, no ve el contenido |
| **Routing** | Por path/host (`/api`, `/insights`, separar servicios futuros) | No tiene; reenvía la conexión cruda |
| **TLS** | Termina TLS con ACM y hace health checks HTTP contra `/actuator/health` | Passthrough o TLS básico; health check solo TCP |
| **Integración EKS** | El AWS Load Balancer Controller lo gestiona vía Ingress (target-type ip a los pods) | Encaja mejor con `Service type=LoadBalancer` L4 |
| **Rendimiento** | Suficiente para 10.000 req/s HTTP | Latencia menor y millones de conexiones (ideal para protocolos no-HTTP o latencia extrema) |

Se elige **ALB** porque la API es HTTP y se aprovecha el routing L7, la terminación TLS con ACM, los health checks de capa de aplicación y la integración nativa con el Ingress de EKS. Un **NLB** sería la opción si necesitáramos latencia ultrabaja, tráfico no-HTTP (gRPC crudo, TCP/UDP) o IP estática — ninguno aplica a este caso.

---

> El **pipeline CI/CD**, los **templates de IaC** (Terraform + manifiestos Kubernetes) y la **validación contra los requerimientos del challenge** se documentan en el [`README.md`](../README.md) del repositorio.
