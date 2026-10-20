# frontend

SPA mínima **"hola mundo"** (React + Vite). Existe solo para simular un repo
real: el pipeline la compila (`vite build`) y publica el estático resultante
(`dist/`) en S3 + CloudFront. No contiene lógica de negocio.

## Local

```bash
npm install
npm run dev      # http://localhost:5173
npm run build    # genera dist/
```

## Contenedor (solo local, opcional)

```bash
docker build -f Dockerfile -t frontend:dev .
docker run -p 8080:80 frontend:dev
```

> El deploy real **no** usa esta imagen: la SPA se publica como estático en
> **S3 + CloudFront** (el pipeline hace `vite build` → `aws s3 sync dist/` →
> invalidación de CloudFront). El Dockerfile está solo para correr la SPA en un
> contenedor local.

La infraestructura y el pipeline que despliegan esta app están en [`../infra/`](../infra/).
