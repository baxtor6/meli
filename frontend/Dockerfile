# ============================================================================
# Dockerfile multi-stage para el frontend (SPA React/Vite "hola mundo").
#
# SOLO USO LOCAL / opcional. El deploy "real" del frontend NO usa esta imagen:
# la SPA se publica como estatico en S3 + CloudFront (el pipeline hace
# `vite build` -> `aws s3 sync dist/` -> invalidacion). Ver infra/architecture.md
# e infra/terraform/{s3_frontend.tf,cloudfront.tf}.
#
# Esta imagen nginx sirve para correr la SPA en un contenedor en local
# (`docker run`) o como fallback si algun entorno prefiere servirla desde un pod.
# ============================================================================

# --- Etapa 1: build ---
FROM node:20-alpine AS build
WORKDIR /app

COPY package.json ./
RUN npm install

COPY . .
RUN npm run build

# --- Etapa 2: runtime (nginx estatico) ---
FROM nginx:1.27-alpine AS runtime
COPY --from=build /app/dist /usr/share/nginx/html
EXPOSE 80
