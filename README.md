# Seller Dashboard — DevOps Round II

Solución al challenge **DevOps Round II**: desplegar en producción el *Seller Dashboard* (Spring Boot + React), expuesto a internet, dimensionado para **10,000 requests/segundo** sostenidos con picos tipo Black Friday, con foco en **resiliencia, seguridad y escalabilidad**.

Este repo simula un **monorepo** autocontenido: las dos aplicaciones (`backend/`, `frontend/`) son mínimas ("hola mundo", no tienen lógica de negocio) y existen solo para que el pipeline y la infraestructura tengan algo real que construir y desplegar. Todo lo de DevOps vive en `infra/`.

> El diseño extendido y las justificaciones por componente están en [`infra/architecture.md`](./infra/architecture.md).
> El diagrama de arquitectura está en [`infra/architecture.drawio`](./infra/architecture.drawio).

---

## 1. Qué pide el challenge y dónde se resuelve

| # | Requerimiento del enunciado | Entregable | Estado |
|---|---|---|---|
| 1 | **Arquitectura de solución** para exponer la API a internet en cloud, resiliente, segura y escalable (diagrama draw.io o similar) | [`infra/architecture.drawio`](./infra/architecture.drawio) + [`infra/architecture.md`](./infra/architecture.md) | ✅ |
| 2 | **CI/CD pipeline**: tareas paso a paso, idea de manifiestos y tecnología (no requiere ser 100% funcional) | [`.github/workflows/ci-cd.yml`](./.github/workflows/ci-cd.yml) + sección "Pipeline CI/CD" (abajo) | ✅ |
| 3 | **IaC**: template(s) para desplegar en cloud (no requiere desplegar en una cuenta real) | [`infra/terraform/`](./infra/terraform/) (17 archivos) + manifiestos K8s en [`infra/k8s/`](./infra/k8s/) + Dockerfiles de [`backend/`](./backend/Dockerfile) y [`frontend/`](./frontend/Dockerfile) | ✅ |

> **Nota sobre el alcance**: el enunciado aclara que *no es necesario desplegar en una cuenta/tenant real*. Por eso el Terraform usa **backend local** de state y los dominios/ARNs/secretos son **placeholders**. Todo está escrito para ser arquitectónicamente correcto y pasar validación estática, no para un `apply` directo sin revisión de nombres/CIDRs/costos.

---

## 2. Estructura del repositorio

```
.
├── README.md             # este documento
├── .github/
│   └── workflows/
│       └── ci-cd.yml     # pipeline CI/CD (GitHub Actions) — ejecutable desde aquí
├── backend/              # app Spring Boot "hola mundo" + Dockerfile
│   ├── src/ ...           # GET / -> "hola mundo", /actuator/health
│   ├── build.gradle
│   └── Dockerfile        # imagen que se despliega en EKS
├── frontend/             # SPA React/Vite "hola mundo" + Dockerfile
│   ├── src/ ...           # muestra "hola mundo desde el frontend"
│   ├── package.json
│   └── Dockerfile        # build Vite -> nginx (el deploy real publica dist/ en S3)
└── infra/                # todo lo de DevOps (Parte 2)
    ├── architecture.md         # diseño detallado + justificación por componente
    ├── architecture.drawio     # fuente editable del diagrama
    ├── terraform/              # IaC (VPC, EKS + add-ons, RDS, Redis, WAF, CloudFront, Route53, ACM, Secrets, SQS)
    ├── k8s/                    # manifiestos Kustomize (base + overlays)
    └── k6/                     # load test
```

Las apps tienen su propio README: [`backend/README.md`](./backend/README.md) y [`frontend/README.md`](./frontend/README.md).

---

## 3. Cloud objetivo y supuestos

- **Cloud**: AWS (los servicios tienen equivalente directo en GCP/Azure, indicados en `infra/architecture.md`).
- **Carga**: 10,000 req/s sostenidos, picos de hasta 10x.
- **Base de datos**: en producción el backend usaría **PostgreSQL gestionado (RDS)**, apto para múltiples réplicas y persistencia real (la app de este repo es un "hola mundo" sin base de datos).
- **Cómputo**: contenedores sobre **EKS (Kubernetes)** por autoscaling fino, multi-AZ y portabilidad.
- **Región de ejemplo**: `us-east-1`, 3 Availability Zones.

---

## 4. Arquitectura de solución (Punto 1)

Flujo de una request, de afuera hacia adentro:

```
Internet
  │
  ▼
Route53  (DNS, ALIAS al edge)
  │
  ▼
CloudFront  (1 distribución, 2 orígenes, TLS en el edge, WAF edge)
  │
  ├── /*      ──►  S3  (SPA estática del frontend/, bucket privado vía OAC)
  │                   └── fallback SPA: rutas de navegación → /index.html (CloudFront Function)
  │
  └── /api/*  ──►  ALB (L7, HTTPS, ACM)  ── WAF regional
                      │   (CloudFront Function quita el prefijo /api)
                      ▼
                   EKS Ingress (AWS LB Controller) → API Pods (HPA 6–60)
                      │                                   │
                      │                                   ├──► ElastiCache Redis   (cache + rate-limit distribuido)
                      │                                   ├──► RDS PostgreSQL primary (escrituras)
                      │                                   ├──► RDS read replicas      (insights/reportes)
                      │                                   └──► SQS ──► Workers de notificación (async)
                      │
                      └── Observabilidad transversal: CloudWatch (métricas/Container Insights, logs, alarmas → SNS)
```

> **Un solo dominio, dos orígenes.** La SPA del `frontend/` se sirve como estático desde **S3 + CloudFront** (no pasa por EKS); la API del `backend/` se sirve bajo **`/api/*`** y es lo único que corre en los pods de EKS. El reparto lo hace CloudFront por path.

### 4.1 Borde / Perímetro
- **Route53** — hosted zone + ALIAS `api.*` → CloudFront (y validación DNS de ACM). El registro `origin.*` → ALB lo publica ExternalDNS desde el Ingress. Permite failover y geo-routing. → [`route53.tf`](./infra/terraform/route53.tf)
- **CloudFront** — TLS en el edge cerca del usuario, absorción de picos, DDoS (Shield Standard). Para la API va en `CachingDisabled` (respuestas dinámicas con `Authorization`); la SPA estática sí se cachea. → [`cloudfront.tf`](./infra/terraform/cloudfront.tf)
- **WAF (WAFv2)** — dos Web ACLs (defensa en profundidad): una en el edge (CloudFront) y otra regional (ALB). Rate-limiting por IP + AWS Managed Rules (Common, SQLi, Known Bad Inputs, IP Reputation). → [`waf.tf`](./infra/terraform/waf.tf)
- **ACM** — certificados TLS con renovación automática: uno regional (ALB) y uno en `us-east-1` (requisito de CloudFront). Validados por DNS. → [`acm.tf`](./infra/terraform/acm.tf)

### 4.2 Red (VPC)
VPC multi-AZ con tres capas de subnets por zona: públicas (ALB/NAT), privadas de app (pods EKS, salida solo vía NAT) y privadas de datos (RDS/Redis, **sin ruta a internet**). → [`vpc.tf`](./infra/terraform/vpc.tf), [`security_groups.tf`](./infra/terraform/security_groups.tf)

### 4.3 Aplicación
- **ALB (L7)** — termina TLS, health checks a `/actuator/health`, balanceo entre AZs. Lo crea el **AWS Load Balancer Controller** a partir del [`Ingress`](./infra/k8s/base/ingress.yaml) (Opción A), con target-type `ip` que registra los pods directamente.
- **EKS** — pods del API con **HPA 6–60 réplicas** por **utilización de CPU** (mínimo 2 por AZ para tolerar caída de zona; máximo dimensionado a ~170 req/s por pod para los 10k req/s). IRSA para credenciales sin claves estáticas. → [`eks.tf`](./infra/terraform/eks.tf)
- **Add-ons del cluster** — LB Controller, Cluster Autoscaler (escala nodos), metrics-server (métricas de CPU del HPA), ExternalDNS (DNS del ALB) y Secrets Store CSI (monta secretos de Secrets Manager), cada uno con IRSA. → [`eks_addons.tf`](./infra/terraform/eks_addons.tf)
- **ElastiCache Redis** — cache distribuida compartida entre pods y contadores de rate-limiting. → [`elasticache.tf`](./infra/terraform/elasticache.tf)

### 4.4 Datos
- **RDS PostgreSQL Multi-AZ** — failover automático; réplicas de lectura para endpoints de solo lectura, liberando el primary para escrituras. → [`rds.tf`](./infra/terraform/rds.tf)

### 4.5 Asíncrono
- **SQS + DLQ** — desacopla las notificaciones del request del usuario; workers escalan por separado y reintentan con backoff. → [`sqs.tf`](./infra/terraform/sqs.tf)

### 4.6 Seguridad transversal
- **Secrets Manager** (credenciales DB/JWT, nunca en imagen ni manifiesto), **IAM/IRSA least-privilege**, Security Groups por capa, subnets de datos aisladas. → [`secrets.tf`](./infra/terraform/secrets.tf), [`eks.tf`](./infra/terraform/eks.tf)

### Cómo se cumplen los tres atributos pedidos
- **Resiliencia**: multi-AZ (red, nodos, RDS, Redis), RDS Multi-AZ con failover, HPA, PodDisruptionBudget + anti-affinity, DLQ en SQS.
- **Seguridad**: CloudFront + WAF (x2) + ACM/TLS, subnets privadas sin salida, Secrets Manager, IAM/IRSA mínimo privilegio, SGs encadenados por capa, pods no-root con rootfs de solo lectura.
- **Escalabilidad**: HPA por CPU, read replicas, Redis compartido, CDN en el edge, autoscaling de nodos EKS y de storage RDS.

> **Extensión futura — autoscaling por requests/segundo**: el HPA base escala solo por CPU (vía metrics-server), suficiente para el alcance del challenge. Para escalar directamente por req/s (señal más precisa en una API I/O-bound) se añadiría Prometheus (scrapea `/actuator/prometheus`) + Prometheus Adapter (expone la métrica a la Custom Metrics API) y un segundo target `Pods` en el HPA (~170 req/s por pod). Queda documentado como ruta, fuera del stack base.

---

## 5. Pipeline CI/CD (Punto 2) — despliegue selectivo por carpeta

Stack: **GitHub Actions** como orquestador de CI, y para el resto **servicios nativos de AWS** — Amazon ECR + Amazon Inspector (imágenes y escaneo), Amazon EKS (`kubectl apply -k`), Amazon S3 + CloudFront (estático del frontend) y Amazon SNS (notificaciones). Workflow ilustrativo en [`.github/workflows/ci-cd.yml`](./.github/workflows/ci-cd.yml) (no ejecutable tal cual: faltan secrets, roles IAM y nombres de recursos reales).

**Idea clave**: el pipeline **solo construye y despliega lo que cambió**. Un primer job (`changes`) usa path filters sobre el diff del PR y publica tres flags (`backend`, `frontend`, `infra`); el resto de los jobs se activan por su `if`:

| Si cambió… | Qué corre | A dónde despliega |
|---|---|---|
| `backend/**` | build + test (Gradle) → imagen a ECR (scan Inspector) → `kubectl apply -k` | **EKS** (rolling update, `rollout undo` si falla) |
| `frontend/**` | build + test (Vite) → `aws s3 sync dist/` → invalidación CloudFront | **S3 + CloudFront** (edge) |
| `infra/**` | `terraform fmt/validate` + `kubectl kustomize` de los overlays | no despliega (validación; `apply` real requiere aprobación fuera de banda) |

Así, un PR que solo toca el `frontend/` no dispara el build de la imagen del backend ni el deploy a EKS, y viceversa. Si un PR toca varias carpetas, corren los flujos correspondientes en paralelo.

Reglas transversales:
- **Trigger**: PR contra `main`. Con el PR abierto corre solo validación (build/test); el **deploy** se dispara únicamente al **mergear** el PR (`github.event.pull_request.merged == true`). No se usa `push: main` (rama protegida, sin commits directos).
- **Sin credenciales estáticas**: el CI asume un rol de IAM (`AWS_CI_ROLE_ARN`); contra EKS usa `aws eks update-kubeconfig`.
- **Aprobación manual** a producción vía GitHub Environment `production` (required reviewers).
- **Trazabilidad**: cada imagen lleva tag inmutable = SHA del commit; el deploy queda asociado al PR mergeado y al run de Actions.

**Por qué `kubectl apply -k` directo a EKS** (y no GitOps): mantiene todo el flujo dentro de servicios gestionados de AWS, sin herramientas de terceros. Como extensión para múltiples servicios/equipos, GitOps con reconciliación continua sería el siguiente paso.

---

## 6. Infraestructura como código (Punto 3)

### 6.1 Terraform — [`infra/terraform/`](./infra/terraform/)

| Archivo | Contenido |
|---|---|
| `main.tf` | terraform block (backend local), providers (aws default + alias `us_east_1`, `kubernetes`, `helm`, `tls`), data sources y auth del cluster |
| `vpc.tf` | VPC, subnets públicas/privadas-app/privadas-datos, IGW, NAT Gateways, route tables |
| `security_groups.tf` | SGs encadenados por capa (ALB → EKS → RDS/Redis) |
| `eks.tf` | cluster EKS, node group con autoscaling, roles IAM, OIDC (thumbprint dinámico) + IRSA del API |
| `eks_addons.tf` | add-ons gestionados (vpc-cni/coredns/kube-proxy) + controllers vía Helm con IRSA: AWS LB Controller, Cluster Autoscaler, metrics-server, ExternalDNS, Secrets Store CSI |
| `s3_alb_logs.tf` | bucket S3 de access logs del ALB (insumo que el Ingress referencia) |
| `s3_frontend.tf` | bucket S3 privado de la SPA (frontend) + Origin Access Control (OAC) + bucket policy solo-CloudFront |
| `waf.tf` | Web ACLs WAFv2 (edge + regional) con rate-limit y Managed Rules |
| `cloudfront.tf` | distribución CloudFront con 2 orígenes: `/*` → S3 (SPA) y `/api/*` → ALB; 2 CloudFront Functions (strip `/api`, fallback SPA); WAF edge, cert us-east-1 |
| `route53.tf` | hosted zone + validación DNS de ACM (el registro del ALB lo gestiona ExternalDNS) |
| `acm.tf` | certificados TLS (ALB regional + CloudFront us-east-1) |
| `rds.tf` | PostgreSQL Multi-AZ + read replicas |
| `elasticache.tf` | ElastiCache Redis (shards + réplicas, Multi-AZ) |
| `secrets.tf` | Secrets Manager (credenciales DB + clave JWT) |
| `sqs.tf` | cola SQS de notificaciones + DLQ |
| `variables.tf` | parametrización (región, CIDRs, tamaños, dominios, rate-limit, versiones de add-ons/charts) |
| `outputs.tf` | salidas (hostname/SG/cert/bucket del ALB, endpoints, ARNs, URL pública) |

> **Propiedad del ALB**: el ALB **no** lo crea Terraform sino el **AWS Load Balancer Controller** a partir del [`Ingress`](./infra/k8s/base/ingress.yaml) (single source of truth, patrón idiomático en EKS). Terraform aporta los insumos (certificado ACM, WAF regional, SG, bucket de logs) y los expone como outputs que el pipeline inyecta en las annotations del Ingress. El registro DNS del ALB lo publica **ExternalDNS**; CloudFront usa ese hostname estable (`var.domain_name`) como origin.

### 6.2 Manifiestos Kubernetes — [`infra/k8s/`](./infra/k8s/)

```
k8s/
├── base/
│   ├── deployment.yaml      # probes /actuator/health, anti-affinity, spread por AZ,
│   │                        # resources, securityContext no-root, rootfs read-only
│   ├── service.yaml         # ClusterIP
│   ├── ingress.yaml         # dueño del ALB: LB Controller lo crea (WAF+ACM+logs+ExternalDNS)
│   ├── hpa.yaml             # 6–60 réplicas (CPU)
│   ├── pdb.yaml             # minAvailable 4
│   ├── serviceaccount.yaml  # IRSA (enlaza al rol de eks.tf)
│   └── kustomization.yaml
└── overlays/
    ├── staging/             # menos réplicas/recursos, host de staging
    └── production/          # valores de la base, host público
```

---

## 7. Cómo validar localmente

El repo no se despliega en cloud (por diseño del challenge), pero sí se valida estáticamente:

```bash
# Infra · Terraform: sintaxis, consistencia y formato
cd infra/terraform
terraform init -backend=false
terraform validate          # => Success! The configuration is valid.
terraform fmt -check -recursive

# Infra · Kubernetes: que los overlays compilan
cd ../..
kubectl kustomize infra/k8s/overlays/staging
kubectl kustomize infra/k8s/overlays/production

# Apps (opcional): que compilan los "hola mundo"
cd backend && gradle build && cd ..
cd frontend && npm install && npm run build && cd ..
```

Estado verificado de la infra: `terraform validate` → **Success**, `terraform fmt -check` → **limpio**, `kubectl kustomize` → compila ambos overlays sin warnings.

---

## 8. Limitaciones conscientes (alcance del challenge)

- **Apps "hola mundo"**: `backend/` y `frontend/` son mínimos a propósito; existen para que el pipeline/infra tengan algo que construir y desplegar, no para implementar lógica de negocio.
- **No se despliega**: state local, dominios/ARNs/secretos son placeholders. En producción: state remoto en S3 con lock, dominios reales, ARNs resueltos por el pipeline, endpoint público de EKS restringido a IPs de oficina/VPN.
- **Propiedad del ALB (decisión tomada)**: el ALB tiene **una sola fuente de verdad**, el AWS Load Balancer Controller vía el Ingress. Terraform ya no crea el ALB; solo aporta insumos (ACM, WAF, SG, bucket de logs) y ExternalDNS publica su hostname. Se descartó que Terraform y el controller lo gestionaran a la vez (habría causado drift y, en un `apply` real, dos ALBs en conflicto).
- **Orden de aplicación**: en un despliegue real, `eks_addons.tf` (providers `helm`/`kubernetes`) requiere que el cluster EKS ya exista y sea alcanzable. Suele hacerse en dos fases (primero la infra base, luego los add-ons) o separando en dos states; aquí conviven en un solo módulo por simplicidad del challenge.
- **Versiones de add-ons/charts**: los valores en `eks_addon_versions` y `helm_chart_versions` son placeholders razonables; en real se fijan según la versión del cluster y se prueban en staging.
- La verificación llega hasta validación estática (`terraform validate`, `kubectl kustomize`); no se ejecutó `terraform apply`, `docker build` ni `k6 run` reales.
