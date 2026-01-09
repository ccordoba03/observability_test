
########################################
# Etiquetas comunes
########################################
locals {
  tags = {
    Project     = "eks-observability-challenge"
    Provisioner = "Terraform"
  }
}

########################################
# VPC (subnets públicas/privadas + tags para ALB)
########################################
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.1"

  name = "${var.cluster_name}-vpc"
  cidr = var.vpc_cidr

  azs             = ["${var.region}a", "${var.region}b", "${var.region}c"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = true

  # Tags necesarias para auto-discovery del AWS Load Balancer Controller
  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }

  tags = local.tags
}

########################################
# EKS (control plane)
########################################
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.34"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  enable_irsa = true


  # Endpoint seguro: público + privado; cidrs restringido a ip local.
  cluster_endpoint_public_access       = true
  cluster_endpoint_private_access      = true
  cluster_endpoint_public_access_cidrs = var.allowed_cidrs

  tags = local.tags
}

########################################
# Karpenter (submódulo IAM/SQS/Pod Identity de EKS - v20.x)
########################################
module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 20.34"

  cluster_name = module.eks.cluster_name

  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  tags = local.tags
}


########################################
# EC2NodeClass (cómo se lanzan los nodos)
########################################
resource "kubernetes_manifest" "karpenter_nodeclass" {
  manifest = {
    apiVersion = "karpenter.k8s.aws/v1beta1"
    kind       = "EC2NodeClass"
    metadata   = {
      name = "default"
    }
    spec = {
      amiFamily = "AL2023"

      # Subnets privadas por tag (creadas por el módulo VPC)
      subnetSelectorTerms = [
        { tags = { "kubernetes.io/role/internal-elb" = "1" } }
      ]

      # Security Group del clúster por tag
      securityGroupSelectorTerms = [
        { tags = { "kubernetes.io/cluster/${module.eks.cluster_name}" = "owned" } }
      ]

   
      role = module.karpenter.node_iam_role_name

      # Tags EC2 útiles para discovery y gobernanza
      tags = {
        "karpenter.sh/discovery" = module.eks.cluster_name
      }
    }
  }

  depends_on = [module.karpenter]
}


########################################
# NodePool (qué nodos + límites + consolidación)
########################################
resource "kubernetes_manifest" "karpenter_nodepool" {
  manifest = {
    apiVersion = "karpenter.sh/v1beta1"
    kind       = "NodePool"
    metadata   = { name = "default" }
    spec = {
      template = {
        metadata = {
          labels = { "provisioner" = "karpenter" }
        }
        spec = {
          nodeClassRef = {
            apiVersion = "karpenter.k8s.aws/v1beta1"
            kind       = "EC2NodeClass"
            name       = "default"   # << nombre fijo; evita la referencia inexistente
          }
          requirements = [
            { key = "karpenter.sh/capacity-type", operator = "In", values = ["on-demand"] },
            { key = "node.kubernetes.io/instance-type", operator = "In", values = ["t3.medium", "m5.large"] }
          ]
        }
      }

      # Límite global del pool (evita escalado sin control)
      limits = { cpu = "200", memory = "400Gi" }

      # Política de consolidación (ahorro de costes)
      disruption = {
        consolidationPolicy = "WhenUnderutilized"
      }
    }
  }

  depends_on = [kubernetes_manifest.karpenter_nodeclass]
}

########################################
# RBAC: Roles Admin y Developer
########################################

# ClusterRoleBinding para Admin (acceso total)
resource "kubernetes_cluster_role_binding" "admin" {
  metadata {
    name = "admin-cluster-admin"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "cluster-admin"
  }
  subject {
    kind      = "User"
    name      = "admin-user"  # Simulado
    api_group = ""
  }
  depends_on = [module.eks]
}

# Namespace para developer
resource "kubernetes_namespace" "developer" {
  metadata {
    name = "developer-ns"
  }
  depends_on = [module.eks]
}

# Role para Developer (solo lectura en developer-ns)
resource "kubernetes_role" "developer" {
  metadata {
    name      = "developer-view"
    namespace = kubernetes_namespace.developer.metadata[0].name
  }
  rule {
    api_groups = [""]
    resources  = ["pods", "services", "configmaps"]
    verbs      = ["get", "list", "watch"]
  }
  depends_on = [kubernetes_namespace.developer]
}

# RoleBinding para Developer
resource "kubernetes_role_binding" "developer" {
  metadata {
    name      = "developer-binding"
    namespace = kubernetes_namespace.developer.metadata[0].name
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.developer.metadata[0].name
  }
  subject {
    kind      = "User"
    name      = "developer-user"  # Simulado
    api_group = ""
  }
  depends_on = [kubernetes_role.developer]
}

########################################
# Grafana Alloy para Observabilidad
########################################

# Namespace para observabilidad
resource "kubernetes_namespace" "observability" {
  metadata {
    name = "observability"
  }
  depends_on = [module.eks]
}



# Módulo para Amazon Managed Prometheus
module "amp" {
  source  = "terraform-aws-modules/managed-service-prometheus/aws"
  version = "~> 1.0"

  workspace_alias = "eks-observability-amp"
  alert_manager_definition = <<EOF
alertmanager_config: |
  route:
    group_by: ['alertname']
    group_wait: 10s
    group_interval: 10s
    repeat_interval: 1h
    receiver: 'null'
  receivers:
  - name: 'null'
EOF
}

# Data source para obtener el endpoint de AMP
data "aws_prometheus_workspace" "this" {
  workspace_id = module.amp.workspace_id
}

# IAM Role para Alloy
resource "aws_iam_role" "alloy_role" {
  name = "GrafanaAlloyRole-eks-observability"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = module.eks.oidc_provider_arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${module.eks.oidc_provider}:sub" = "system:serviceaccount:observability:grafana-alloy"
          }
        }
      }
    ]
  })

  inline_policy {
    name = "AMPWritePolicy"
    policy = jsonencode({
      Version = "2012-10-17"
      Statement = [
        {
          Effect = "Allow"
          Action = [
            "aps:RemoteWrite",
            "aps:GetSeries",
            "aps:GetLabels",
            "aps:GetMetricMetadata"
          ]
          Resource = module.amp.workspace_arn
        }
      ]
    })
  }

  tags = local.tags
}

# Service Account para Alloy
resource "kubernetes_service_account" "alloy_sa" {
  metadata {
    name      = "grafana-alloy"
    namespace = kubernetes_namespace.observability.metadata[0].name
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.alloy_role.arn
    }
  }
  depends_on = [kubernetes_namespace.observability]
}

########################################
# Aplicación Demo
########################################

# Namespace para app
resource "kubernetes_namespace" "app" {
  metadata {
    name = "app-demo"
  }
  depends_on = [module.eks]
}

# Deployment de la app
resource "kubernetes_manifest" "app_deployment" {
  manifest = {
    apiVersion = "apps/v1"
    kind       = "Deployment"
    metadata = {
      name      = "hello-world"
      namespace = kubernetes_namespace.app.metadata[0].name
    }
    spec = {
      replicas = 1
      selector = {
        matchLabels = {
          app = "hello-world"
        }
      }
      template = {
        metadata = {
          labels = {
            app = "hello-world"
          }
        }
        spec = {
          containers = [
            {
              name  = "hello-world"
              image = "nginx:alpine"
              ports = [
                {
                  containerPort = 80
                }
              ]
              envFrom = [
                {
                  secretRef = {
                    name = "app-secret"
                  }
                }
              ]
            }
          ]
        }
      }
    }
  }
  depends_on = [kubernetes_namespace.app]
}

# Service
resource "kubernetes_manifest" "app_service" {
  manifest = {
    apiVersion = "v1"
    kind       = "Service"
    metadata = {
      name      = "hello-world"
      namespace = kubernetes_namespace.app.metadata[0].name
    }
    spec = {
      selector = {
        app = "hello-world"
      }
      ports = [
        {
          port        = 80
          targetPort  = 80
          protocol    = "TCP"
        }
      ]
      type = "ClusterIP"
    }
  }
  depends_on = [kubernetes_manifest.app_deployment]
}

# Ingress
resource "kubernetes_manifest" "app_ingress" {
  manifest = {
    apiVersion = "networking.k8s.io/v1"
    kind       = "Ingress"
    metadata = {
      name      = "hello-world"
      namespace = kubernetes_namespace.app.metadata[0].name
      annotations = {
        "kubernetes.io/ingress.class" = "alb"
        "alb.ingress.kubernetes.io/scheme" = "internet-facing"
        "alb.ingress.kubernetes.io/target-type" = "ip"
      }
    }
    spec = {
      rules = [
        {
          http = {
            paths = [
              {
                path     = "/"
                pathType = "Prefix"
                backend = {
                  service = {
                    name = "hello-world"
                    port = {
                      number = 80
                    }
                  }
                }
              }
            ]
          }
        }
      ]
    }
  }
  depends_on = [kubernetes_manifest.app_service]
}



# IAM Role para ALB Controller
resource "aws_iam_role" "alb_controller_role" {
  name = "ALBControllerRole-eks-observability"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = module.eks.oidc_provider_arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${module.eks.oidc_provider}:sub" = "system:serviceaccount:kube-system:aws-load-balancer-controller"
          }
        }
      }
    ]
  })

  managed_policy_arns = [
    "arn:aws:iam::aws:policy/ElasticLoadBalancingFullAccess",
    "arn:aws:iam::aws:policy/AmazonEC2ReadOnlyAccess"
  ]

  tags = local.tags
}

# Service Account para ALB Controller
resource "kubernetes_service_account" "alb_sa" {
  metadata {
    name      = "aws-load-balancer-controller"
    namespace = "kube-system"
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.alb_controller_role.arn
    }
  }
  depends_on = [module.eks]
}
## Secret en AWS Secrets Manager 
data "aws_secretsmanager_secret" "app_secret" {
  name = var.app_secret_name
}

# SecretStore
resource "kubectl_manifest" "secret_store" {
  yaml_body = yamlencode({
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "SecretStore"
    metadata = {
      name      = "aws-secretsmanager"
      namespace = kubernetes_namespace.app.metadata[0].name
    }
    spec = {
      provider = {
        aws = {
          service = "SecretsManager"
          region  = var.region
          auth = {
            jwt = {
              serviceAccountRef = {
                name = kubernetes_service_account.app_sa.metadata[0].name
              }
            }
          }
        }
      }
    }
  })
  depends_on = [kubernetes_namespace.app]
}

# ExternalSecret
resource "kubectl_manifest" "app_secret" {
  yaml_body = yamlencode({
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "app-secret"
      namespace = kubernetes_namespace.app.metadata[0].name
    }
    spec = {
      refreshInterval = "15s"
      secretStoreRef = {
        name = "aws-secretsmanager"
        kind = "SecretStore"
      }
      target = {
        name = "app-secret"
        creationPolicy = "Owner"
      }
      data = [
        {
          secretKey = "API_KEY"
          remoteRef = {
            key = var.app_secret_name
          }
        }
      ]
    }
  })
  depends_on = [kubectl_manifest.secret_store]
}

# Service Account para ESO
resource "kubernetes_service_account" "app_sa" {
  metadata {
    name      = "app-sa"
    namespace = kubernetes_namespace.app.metadata[0].name
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.app_role.arn
    }
  }
  depends_on = [kubernetes_namespace.app]
}

# IAM Role para la app
resource "aws_iam_role" "app_role" {
  name = "AppRole-eks-observability"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = module.eks.oidc_provider_arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${module.eks.oidc_provider}:sub" = "system:serviceaccount:app-demo:app-sa"
          }
        }
      }
    ]
  })

  inline_policy {
    name = "SecretsManagerReadPolicy"
    policy = jsonencode({
      Version = "2012-10-17"
      Statement = [
        {
          Effect = "Allow"
          Action = [
            "secretsmanager:GetSecretValue"
          ]
          Resource = data.aws_secretsmanager_secret.app_secret.arn
        }
      ]
    })
  }

  tags = local.tags
}
