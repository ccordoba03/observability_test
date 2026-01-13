
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

  enable_nat_gateway = true #conexión a internet para nodos privados
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
  enable_cluster_creator_admin_permissions = true

  # Endpoint seguro: público + privado; cidrs restringido a ip local.
  cluster_endpoint_public_access       = true
  cluster_endpoint_private_access      = true
  cluster_endpoint_public_access_cidrs = var.allowed_cidrs

  # SOLUCION DE BUG SOBRE TF INIT PARA MODULOS DE KARPENTER , NECESITA NODOS PARA PODER INICIALIZAR
  eks_managed_node_groups = {
    bootstrap = {
      name            = "bootstrap"
      use_name_prefix = false

      instance_types = ["t3.medium"]

      min_size     = 1
      max_size     = 1
      desired_size = 1

      disk_size = 50

      tags = {
        "karpenter.sh/do-not-consolidate" = "true"
      }
    }
  }

  tags = local.tags
}

# Espera a que el cluster EKS esté listo antes de crear recursos de Kubernetes
resource "time_sleep" "wait_eks_active" {
  create_duration = "90s"
  depends_on      = [module.eks]
}

########################################
# Karpenter (submódulo IAM/SQS/Pod Identity de EKS - v20.x)
########################################
module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 20.34"

  cluster_name = module.eks.cluster_name
#politica de definicion de  usando conex hacia aws system manager
  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  tags = local.tags
}


# Namespace para Karpenter
resource "kubernetes_namespace" "karpenter" {
  metadata {
    name = "karpenter"
  }
  depends_on = [time_sleep.wait_eks_active]
}

########################################
# Karpenter Provisioner
########################################

resource "kubectl_manifest" "karpenter_provisioner" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.sh/v1alpha5"
    kind       = "Provisioner"
    metadata   = {
      name = "default"
    }
    spec = {
      # TTL settings for node cleanup when nodes are empty or expired
      ttlSecondsAfterEmpty = 30
      ttlSecondsUntilExpired = 604800  # 7 days

      # AWS-specific configuration
      providerRef = {
        name = "default"
      }

      # Resource limits

      limits = {
        resources = {
          cpu    = "100"
          memory = "200Gi"
        }
      }

      # Consolidation settings bin packding and dowzising of nodes
      consolidation = {
        enabled = true
      }

      # Requirements for nodes
      requirements = [
        {
          key = "karpenter.sh/capacity-type"
          operator = "In"
          values = ["on-demand"]
        },
        {
          key = "node.kubernetes.io/instance-type"
          operator = "In"
          values = ["t3.medium", "t3.large"]
        },
        {
          key = "kubernetes.io/arch"
          operator = "In"
          values = ["amd64"]
        }
      ]
    }
  })

  depends_on = [kubernetes_namespace.karpenter]
}

########################################
# Karpenter AWSNodeTemplate
########################################

resource "kubectl_manifest" "karpenter_aws_node_template" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.k8s.aws/v1alpha1"
    kind       = "AWSNodeTemplate"
    metadata   = {
      name = "default"
    }
    spec = {
      subnetSelector = {
        "kubernetes.io/role/internal-elb" = "1"
      }
      
      securityGroupSelector = {
        "kubernetes.io/cluster/${module.eks.cluster_name}" = "owned"
      }

      tags = {
        "karpenter.sh/discovery" = module.eks.cluster_name
      }

      iamInstanceProfile = module.karpenter.node_iam_role_name
#CONFIGURACION DE VOLUMENES PARA NODOS KARPENTER /DICOS EBS GP3 DE 50GB
      blockDeviceMappings = [
        {
          deviceName = "/dev/xvda"
          ebs = {
            volumeSize = 50
            volumeType = "gp3"
            deleteOnTermination = true
          }
        }
      ]
    }
  })

  depends_on = [kubernetes_namespace.karpenter]
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
  depends_on = [time_sleep.wait_eks_active]
}

# Namespace para developer
resource "kubernetes_namespace" "developer" {
  metadata {
    name = "developer-ns"
  }
  depends_on = [time_sleep.wait_eks_active]
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

# RoleBinding para Developer // DENTRO DENAMESPACE DEVELOPER_Ns PUEDE VER RECURSOS
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
#grafana y grafana allloy instalados via helm en el clúster EKS ,usando comandos helm 
# Namespace para observabilidad
resource "kubernetes_namespace" "observability" {
  metadata {
    name = "observability"
  }
  depends_on = [time_sleep.wait_eks_active]
}

########################################
# Amazon Managed Prometheus (AMP)
########################################

# Módulo para Amazon Managed Prometheus
module "amp" {
  source  = "terraform-aws-modules/managed-service-prometheus/aws"
  version = "~> 1.0"
#configuracion del workspace de amp , para lectura de metricas desde grafana alloy
#remote_write habilitado
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


# IAM Role para Alloy,  (IAM Roles for Service Accounts /IRSA) 
resource "aws_iam_role" "alloy_role" {
  name = "GrafanaAlloyRole-${var.cluster_name}"
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
  depends_on = [time_sleep.wait_eks_active]
}

# Deployment de la app
resource "kubectl_manifest" "app_deployment" {
  yaml_body = yamlencode({
    apiVersion = "apps/v1"
    kind       = "Deployment"
    metadata = {
      name      = "hello-world"
      namespace = kubernetes_namespace.app.metadata[0].name
    }
    spec = {
      replicas = 1
      progressDeadlineSeconds = 600
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
  })
  depends_on = [kubernetes_namespace.app, time_sleep.wait_eks_active]
}

# Service // stable persistent internal IP para la app

resource "kubectl_manifest" "app_service" {
  yaml_body = yamlencode({
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
  })
  depends_on = [kubectl_manifest.app_deployment]
}

# Ingress
resource "kubectl_manifest" "app_ingress" {
  yaml_body = yamlencode({
    apiVersion = "networking.k8s.io/v1"
    kind       = "Ingress"
    metadata = {
      name      = "hello-world"
      namespace = kubernetes_namespace.app.metadata[0].name
      annotations = {
        # Anotaciones para AWS ALB Ingress Controller aplicationload balancer
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
  })
  depends_on = [kubectl_manifest.app_service]
}
# OIDC = OpenID Connect (estándar de autenticación abierto)
########################################
# ALB Controller IAM Role
########################################

# a partir de la creacion del ingres de la app, se implementa un alb para exponer la app demo
resource "aws_iam_role" "alb_controller_role" {
  name = "ALBControllerRole-${var.cluster_name}"

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

  inline_policy {
    name = "ALB-EC2-Policy"
    policy = jsonencode({
      Version = "2012-10-17"
      Statement = [
        {
          Effect = "Allow"
          Action = [
            "ec2:CreateSecurityGroup",
            "ec2:DeleteSecurityGroup",
            "ec2:AuthorizeSecurityGroupIngress",
            "ec2:RevokeSecurityGroupIngress",
            "ec2:CreateTags"
          ]
          Resource = "*"
        }
      ]
    })
  }

  inline_policy {
    name = "ALB-WAF-Policy"
    policy = jsonencode({
      Version = "2012-10-17"
      Statement = [
        {
          Effect = "Allow"
          Action = [
            "wafv2:GetWebACL",
            "wafv2:GetWebACLForResource",
            "wafv2:AssociateWebACL",
            "wafv2:DisassociateWebACL"
          ]
          Resource = "*"
        }
      ]
    })
  }

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
  depends_on = [time_sleep.wait_eks_active]
}

########################################
# Kubernetes Secrets Configuration
########################################
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
  depends_on = [kubernetes_namespace.app, time_sleep.wait_eks_active]
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
  name = "AppRole-${var.cluster_name}"

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
