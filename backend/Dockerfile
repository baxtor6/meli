# ============================================================================
# Dockerfile multi-stage para el backend (Spring Boot "hola mundo").
# Referenciado por el pipeline: `docker build -f backend/Dockerfile backend`.
#
# Etapa 1 (build): compila el fat-jar con Gradle.
# Etapa 2 (runtime): imagen JRE minima, usuario no-root, solo el jar final.
# ============================================================================

# --- Etapa 1: build ---
FROM gradle:8.7-jdk17 AS build
WORKDIR /app

# Cache de dependencias: copiamos primero los build scripts y resolvemos
# dependencias antes del codigo, para aprovechar la cache de capas de Docker.
COPY build.gradle settings.gradle ./
RUN gradle --no-daemon dependencies || true

COPY src ./src
RUN gradle --no-daemon clean bootJar -x test

# --- Etapa 2: runtime ---
FROM eclipse-temurin:17-jre-jammy AS runtime
WORKDIR /app

# Usuario no-root (menor privilegio dentro del contenedor).
RUN groupadd --system app && useradd --system --gid app --no-create-home app

COPY --from=build /app/build/libs/*.jar app.jar

USER app
EXPOSE 8080

# Flags de JVM para contenedores: respetar limites de cgroups (memoria/CPU)
# que impone Kubernetes en los pods.
ENV JAVA_OPTS="-XX:MaxRAMPercentage=75.0 -XX:InitialRAMPercentage=50.0"

# Healthcheck a nivel de contenedor (Kubernetes usa ademas sus probes).
HEALTHCHECK --interval=15s --timeout=3s --start-period=40s --retries=3 \
  CMD wget -qO- http://localhost:8080/actuator/health | grep -q UP || exit 1

ENTRYPOINT ["sh", "-c", "java $JAVA_OPTS -jar app.jar"]
