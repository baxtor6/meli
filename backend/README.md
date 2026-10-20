# backend

Aplicación mínima **"hola mundo"** (Spring Boot). Existe solo para simular un
repo real: el pipeline la compila y empaqueta en una imagen de contenedor que
se despliega en EKS. No contiene lógica de negocio.

- `GET /` → `hola mundo desde el backend`
- `GET /actuator/health` → usado por las probes de Kubernetes y el healthcheck del contenedor

## Local

```bash
gradle bootRun      # arranca en http://localhost:8080
gradle build        # compila + tests
```

## Contenedor

```bash
docker build -f Dockerfile -t backend:dev .
docker run -p 8080:8080 backend:dev
```

La infraestructura y el pipeline que despliegan esta app están en [`../infra/`](../infra/).
