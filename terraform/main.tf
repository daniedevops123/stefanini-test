terraform {
  required_version = ">= 1.5"

  required_providers {
    http = {
      source  = "hashicorp/http"
      version = "~> 3.0"
    }
  }
}

# ─────────────────────────────────────────────────────
# Variables
# ─────────────────────────────────────────────────────
variable "render_api_key" {
  description = "Render API key. Pasar via: export TF_VAR_render_api_key=rnd_xxx"
  type        = string
  sensitive   = true
}

variable "render_owner_id" {
  description = "Owner ID de tu cuenta Render. Ver en: Account Settings > General"
  type        = string
}

variable "dockerhub_username" {
  description = "Usuario de Docker Hub que contiene la imagen"
  type        = string
  default     = "danvalrl"
}

variable "service_name" {
  description = "Nombre del Web Service en Render"
  type        = string
  default     = "stefanini-json-api"
}

variable "region" {
  description = "Region de despliegue en Render"
  type        = string
  default     = "oregon"

  validation {
    condition     = contains(["oregon", "ohio", "virginia", "frankfurt", "singapore"], var.region)
    error_message = "Region no valida. Usar: oregon, ohio, virginia, frankfurt o singapore."
  }
}

# ─────────────────────────────────────────────────────
# Locals
# ─────────────────────────────────────────────────────
locals {
  image_url   = "docker.io/${var.dockerhub_username}/stefanini-json-api:latest"
  render_api  = "https://api.render.com/v1"
  auth_header = "Bearer ${var.render_api_key}"
}

# ─────────────────────────────────────────────────────
# 1. Verificar que la API key y el owner son validos
# ─────────────────────────────────────────────────────
data "http" "verify_owner" {
  url = "${local.render_api}/owners/${var.render_owner_id}"

  request_headers = {
    Authorization = local.auth_header
    Accept        = "application/json"
  }

  lifecycle {
    postcondition {
      condition     = self.status_code == 200
      error_message = "No se pudo verificar el owner en Render. Revisa render_owner_id y render_api_key."
    }
  }
}

# ─────────────────────────────────────────────────────
# 2. Consultar si el servicio ya existe
# ─────────────────────────────────────────────────────
data "http" "list_services" {
  url = "${local.render_api}/services?ownerId=${var.render_owner_id}&name=${var.service_name}&limit=1"

  request_headers = {
    Authorization = local.auth_header
    Accept        = "application/json"
  }

  depends_on = [data.http.verify_owner]
}

# ─────────────────────────────────────────────────────
# 3. Crear el Web Service en Render via API REST
#
#    Render no tiene provider Terraform oficial, por lo
#    que se usa el http provider para validaciones y
#    local-exec + curl para la creacion del servicio.
# ─────────────────────────────────────────────────────
resource "terraform_data" "render_service" {
  triggers_replace = {
    image_url    = local.image_url
    service_name = var.service_name
    region       = var.region
  }

  provisioner "local-exec" {
    command = <<-EOT
      echo "Creando servicio '${var.service_name}' en Render (region: ${var.region})..."
      curl -sf -X POST "${local.render_api}/services" \
        -H "Authorization: ${local.auth_header}" \
        -H "Content-Type: application/json" \
        -d '{
          "type": "web_service",
          "name": "${var.service_name}",
          "ownerId": "${var.render_owner_id}",
          "region": "${var.region}",
          "plan": "free",
          "serviceDetails": {
            "runtime": "image",
            "image": {
              "ownerId": "${var.render_owner_id}",
              "imagePath": "${local.image_url}"
            },
            "healthCheckPath": "/products",
            "envVars": [
              { "key": "PORT", "value": "3000" }
            ]
          }
        }' | python3 -c "
import sys, json
r = json.load(sys.stdin)
svc = r.get('service', r)
print('Servicio creado:')
print('  ID  :', svc.get('id', 'n/a'))
print('  URL :', svc.get('serviceDetails', {}).get('url', 'pendiente'))
print('  Plan:', svc.get('plan', 'n/a'))
"
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = "echo 'Para eliminar el servicio ve a dashboard.render.com y eliminalo manualmente.'"
  }
}

# ─────────────────────────────────────────────────────
# Outputs
# ─────────────────────────────────────────────────────
output "image_url" {
  description = "Imagen Docker desplegada"
  value       = local.image_url
}

output "service_name" {
  description = "Nombre del servicio en Render"
  value       = var.service_name
}

output "region" {
  description = "Region de despliegue"
  value       = var.region
}

output "render_dashboard" {
  description = "URL del dashboard de Render"
  value       = "https://dashboard.render.com"
}

output "api_endpoints" {
  description = "Endpoints REST disponibles tras el despliegue"
  value = {
    list_products  = "GET    /products"
    get_product    = "GET    /products/:id"
    list_users     = "GET    /users"
    list_orders    = "GET    /orders"
    create_product = "POST   /products  (body JSON)"
    update_product = "PUT    /products/:id"
    delete_product = "DELETE /products/:id"
  }
}

output "next_steps" {
  description = "Pasos para usar este template"
  value       = <<-EOT
    1. cp terraform.tfvars.example terraform.tfvars
    2. Completar los valores en terraform.tfvars
    3. terraform init
    4. terraform plan
    5. terraform apply

    Donde obtener los valores:
      render_api_key   -> dashboard.render.com > Account Settings > API Keys
      render_owner_id  -> dashboard.render.com > Account Settings > General (User ID)
      dockerhub_username -> tu usuario de hub.docker.com
  EOT
}
