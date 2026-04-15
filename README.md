# Stefanini DevOps Technical Test — CI/CD + Cloud

> **Aplicación:** JSON Server REST API mock  
> **CI/CD:** GitHub Actions  
> **Cloud:** Render  
> **IaC:** Terraform  
> **Containerización:** Docker  

---

## Tabla de Contenidos

1. [Decisiones Técnicas](#1-decisiones-técnicas)
2. [Estructura del Repositorio](#2-estructura-del-repositorio)
3. [Pipeline CI/CD](#3-pipeline-cicd)
4. [Arquitectura y Flujo de Tráfico](#4-arquitectura-y-flujo-de-tráfico)
5. [Estrategia de Persistencia](#5-estrategia-de-persistencia)
6. [Infraestructura como Código](#6-infraestructura-como-código)
7. [Cómo Acceder a la App](#7-cómo-acceder-a-la-app)
8. [Ejecución Local](#8-ejecución-local)
9. [Secrets Requeridos](#9-secrets-requeridos)
10. [Uso de IA](#10-uso-de-ia)

---

## 1. Decisiones Técnicas

### ¿Qué aplicación elegí y por qué?

**Opción 2 – JSON Server** (`typicode/json-server`)

JSON Server expone una REST API completa (GET / POST / PUT / DELETE) leyendo un archivo `db.json`. Es ideal para esta prueba porque:
- No requiere base de datos externa ni variables de entorno complejas.
- El foco es la automatización, no la lógica de negocio.
- El comportamiento es predecible y fácil de validar en el pipeline con `curl`.

El archivo `data/db.json` incluye tres colecciones de ejemplo: `products`, `users` y `orders`.

---

### ¿Qué herramienta CI/CD elegí y por qué?

**GitHub Actions**

| Criterio | Razón |
|---|---|
| Sin infraestructura propia | No requiere servidor Jenkins ni agentes autoalojados. |
| Integración nativa con GitHub | Los eventos `push` y `pull_request` disparan el pipeline sin configuración adicional. |
| Ecosistema de acciones | `docker/build-push-action`, `hadolint/hadolint-action` y otras acciones oficiales reducen el código boilerplate. |
| Caché de capas Docker | `cache-from/cache-to: type=gha` acelera los builds subsiguientes. |
| Gratuito para repos públicos | Sin costo para una prueba técnica. |

---

### ¿Por qué Render?

| Criterio | Razón |
|---|---|
| Plan gratuito con Docker | Render despliega directamente desde una imagen Docker sin configuración de servidor. |
| Zero-ops | No hay que gestionar VMs, grupos de seguridad ni balanceadores. |
| HTTPS automático | TLS/SSL incluido sin certificados manuales. |
| API de deploy | Render expone un endpoint REST para disparar redeploys desde el pipeline. |
| Sin tarjeta de crédito | Ideal para una prueba técnica. |

Alternativas consideradas: Railway (similar), Fly.io (más control, más configuración), AWS ECS (mayor complejidad para el alcance pedido).

---

### ¿Por qué usar Docker?

Docker garantiza que la imagen que se valida en CI es **exactamente** la que se despliega en producción, eliminando el problema de "funciona en mi máquina". Además:
- El `Dockerfile` es reproducible y versionable.
- La imagen se publica en Docker Hub y Render la descarga directamente.
- El `HEALTHCHECK` integrado permite a Render detectar si el contenedor no inició correctamente.

---

## 2. Estructura del Repositorio

```
stefanini-test/
├── .github/
│   └── workflows/
│       └── ci-cd.yml          # Pipeline completo (4 stages)
├── data/
│   └── db.json                # Datos de la API (products, users, orders)
├── terraform/
│   ├── main.tf                # Configuración IaC
│   └── terraform.tfvars.example
├── Dockerfile                 # Imagen de producción
├── docker-compose.yml         # Entorno local
├── render.yaml                # Configuración declarativa para Render
├── .gitignore
└── README.md
```

---

## 3. Pipeline CI/CD

### ¿Qué lo dispara?

| Evento | Comportamiento |
|---|---|
| `push` a `main` | Ejecuta los 4 stages completos (validar → build/test → push imagen → deploy) |
| `pull_request` a `main` | Ejecuta solo los stages 1 y 2 (validación + build/test, sin deploy) |

### Stages

```
push → main
    │
    ▼
┌─────────────┐     ┌──────────────────┐     ┌─────────────────┐     ┌────────────────┐
│  STAGE 1    │────▶│    STAGE 2       │────▶│   STAGE 3       │────▶│   STAGE 4      │
│  Validate   │     │  Build & Test    │     │  Push Image     │     │   Deploy       │
└─────────────┘     └──────────────────┘     └─────────────────┘     └────────────────┘
```

#### Stage 1 — Validate
- **Checkout** del repositorio.
- **Validación de JSON**: `python3 -c "import json; json.load(...)"` — verifica que `db.json` sea JSON válido.
- **Verificación de archivos requeridos**: comprueba que `Dockerfile`, `db.json` y `docker-compose.yml` existen.
- **Lint del Dockerfile**: `hadolint/hadolint-action` detecta malas prácticas (capas innecesarias, instrucciones deprecated, etc.).

#### Stage 2 — Build & Test
- **Docker Buildx** para builds multi-plataforma con caché de GitHub Actions.
- **Build de la imagen** con el SHA del commit como tag.
- **Smoke test automatizado**: levanta el contenedor en el runner, espera a que el healthcheck pase y valida los tres endpoints (`/products`, `/users`, `/orders`) con `curl` + assertions en Python.
- En caso de fallo, imprime los logs del contenedor para facilitar el diagnóstico.

#### Stage 3 — Push Image *(solo en `main`)*
- Login en **Docker Hub** con secrets cifrados.
- Push de la imagen con dos tags: `latest` y el SHA del commit (para trazabilidad).
- Caché de capas Docker reutilizada entre runs.

#### Stage 4 — Deploy *(solo en `main`)*
- Llama a la **API REST de Render** (`POST /v1/services/{id}/deploys`) para disparar el redeploy.
- Espera 60 segundos para que el servicio reinicie.
- **Verificación post-deploy**: consulta el endpoint `/products` de la URL pública para confirmar que el despliegue fue exitoso.
- Imprime un resumen con la URL y el SHA desplegado.

---

## 4. Arquitectura y Flujo de Tráfico

### 2.1 Diagrama y Análisis

```
Usuario (navegador / curl)
        │
        │ HTTPS (TLS terminado automáticamente)
        ▼
┌─────────────────────────────────────────────────┐
│                  Render Edge Network             │
│   (CDN / Load Balancer global — punto de entrada)│
│   • Termina TLS                                  │
│   • Rate limiting básico                         │
│   • Health check → redirige a instancias sanas   │
└────────────────────┬────────────────────────────┘
                     │ HTTP interno
                     ▼
┌─────────────────────────────────────────────────┐
│            Contenedor Docker (Render)            │
│   Runtime: Node 20 Alpine                        │
│   Proceso: json-server --host 0.0.0.0 --port 3000│
│   • Sirve REST API desde db.json en memoria      │
│   • HEALTHCHECK: GET /products cada 30s          │
└─────────────────────────────────────────────────┘
```

#### Punto de entrada
La URL pública de Render (`https://<service>.onrender.com`) actúa como punto de entrada único. Render gestiona internamente el balanceo y el routing hacia el contenedor.

#### Seguridad
- **TLS/HTTPS automático** provisto por Render (Let's Encrypt) — todo el tráfico externo va cifrado.
- **Red interna aislada** — el contenedor solo es accesible a través del proxy de Render, no está expuesto directamente a internet.
- **Sin credenciales en la imagen** — `db.json` es de solo lectura y no contiene información sensible.

#### Integración con API Gateway (opcional)
En un escenario productivo, se podría agregar un API Gateway (AWS API Gateway, Kong, o Render no lo incluye nativamente) para:
- Autenticación con JWT / API keys.
- Throttling por cliente.
- Logging estructurado de requests.

Para esta prueba, el proxy de Render cumple el rol básico de entrada.

#### Cómputo
El contenedor corre en el plan **Free** de Render (0.1 CPU / 512 MB RAM). Para producción se escalaría a un plan Starter o Standard con más recursos y sin spin-down automático.

---

## 5. Estrategia de Persistencia

### El problema
JSON Server almacena los datos en `db.json` dentro del sistema de archivos del contenedor. Cuando Render reinicia o redespliega el servicio, el contenedor se destruye y **cualquier cambio POST/PUT/DELETE se pierde**.

### Solución propuesta

#### Para desarrollo / prueba técnica (configuración actual)
Los datos se incluyen en la imagen Docker (`COPY data/db.json /app/db.json`). Son de solo lectura y siempre arrancan desde un estado conocido.

#### Para producción — tres alternativas progresivas

**Opción A — Volumen persistente en Render**
Render ofrece **Persistent Disks** en planes pagos. Se monta `/app/db.json` en el disco:
```yaml
# render.yaml
services:
  - type: web
    disk:
      name: api-data
      mountPath: /app/data
      sizeGB: 1
```
La API pasa a leer `--watch /app/data/db.json`. Los cambios sobreviven reinicios.

**Opción B — Backend de base de datos (recomendada para escala)**
Reemplazar JSON Server por una API real (FastAPI, Express) que lea de una base de datos gestionada (PostgreSQL en Render, AWS RDS, o Supabase). Los contenedores son 100% stateless y la persistencia vive fuera de ellos.

**Opción C — Almacenamiento de objetos (S3 / R2)**
`db.json` se almacena en S3 o Cloudflare R2. Al iniciar, el contenedor descarga el archivo; al escribir, lo sube. Útil para escenarios de lectura intensiva con escrituras infrecuentes.

---

## 6. Infraestructura como Código

El directorio `terraform/` contiene un template básico (`main.tf`) que:
- Define variables configurables (`render_api_key`, `dockerhub_username`, `service_name`, `region`).
- Documenta los outputs esperados (nombre del servicio, región, endpoints de la API).
- Sirve como base para extender con providers de Render, AWS o GCP según el entorno.

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# editar terraform.tfvars con tus valores reales
terraform init
terraform plan
terraform apply
```

> **Nota**: Render no tiene un provider Terraform oficial estable. En un entorno AWS/GCP, este template se extendería con recursos ECS/CloudRun + ALB + Route53/Cloud DNS + certificados ACM.

---

## 7. Cómo Acceder a la App

| Endpoint | Descripción |
|---|---|
| `GET /products` | Lista todos los productos |
| `GET /products/1` | Obtiene el producto con id=1 |
| `GET /users` | Lista todos los usuarios |
| `GET /orders` | Lista todas las órdenes |
| `POST /products` | Crea un producto (body JSON) |
| `PUT /products/1` | Actualiza el producto con id=1 |
| `DELETE /products/1` | Elimina el producto con id=1 |

**URL de producción:** Se configura en el secret `RENDER_SERVICE_URL` una vez creado el servicio en Render.

Ejemplo de request:
```bash
curl https://<tu-servicio>.onrender.com/products
```

---

## 8. Ejecución Local

### Con Docker Compose (recomendado)
```bash
git clone https://github.com/daniedevops123/stefanini-test
cd stefanini-test
docker compose up --build
# API disponible en http://localhost:3000
```

### Sin Docker (requiere Node.js 20+)
```bash
npm install -g json-server
json-server --host 0.0.0.0 --port 3000 data/db.json
```

---

## 9. Secrets Requeridos

Configurar en **Settings → Secrets and variables → Actions** del repositorio:

| Secret | Descripción |
|---|---|
| `DOCKERHUB_USERNAME` | Usuario de Docker Hub |
| `DOCKERHUB_TOKEN` | Access token de Docker Hub (no la contraseña) |
| `RENDER_API_KEY` | API key de Render (`Account → API Keys`) |
| `RENDER_SERVICE_ID` | ID del servicio en Render (ej: `srv-xxxxxxxx`) |
| `RENDER_SERVICE_URL` | URL pública del servicio (ej: `https://stefanini-json-api.onrender.com`) |

---

## 10. Uso de IA

Sí, se utilizó IA (Claude de Anthropic) como asistente durante el desarrollo. El proceso fue iterativo: se tomaban decisiones, se encontraban errores reales, y la IA ayudaba a diagnosticar y corregir. No fue generación automática de código sino un trabajo conjunto de ida y vuelta.

### Dónde intervino la IA y cómo

**Corrección de errores durante el build:** Al correr `docker build` falló con `json-server@1 not found`. La IA identificó que esa versión no existe en npm con ese tag y propuso cambiar a `json-server` sin versión fija, lo que resolvió el problema de inmediato.

**Smoke test en el runner de CI:** La validación post-build de los endpoints (`/products`, `/users`, `/orders`) con assertions en Python dentro del propio runner fue una sugerencia de la IA para evitar deployar una imagen que no responde correctamente.

**Terraform funcional:** El template inicial de Terraform era declarativo pero no ejecutable. La IA lo reescribió usando `terraform_data` con `local-exec` y `curl` para llamar a la API REST de Render, dado que no existe un provider oficial.

