variable "region" {
  type    = string
  default = "us-east-1"
}

variable "cluster_name" {
  type    = string
  default = "eks-observability-v2"
}

variable "cluster_version" {
  type    = string
  default = "1.29"
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "allowed_cidrs" {
  description = "CIDRs permitidos para el endpoint público del API del clúster"
  type        = list(string)
  default     = ["181.53.12.236/32"]
}

variable "app_secret_name" {
  description = "Nombre del secreto en AWS Secrets Manager que contiene las credenciales de la app"
  type        = string
  default     = "eks-observability-app-secret"
}
