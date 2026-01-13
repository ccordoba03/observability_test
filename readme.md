# Proyecto: Observabilidad en AWS EKS.

**Última actualización:** 12/01/2025
Se reinicializa el proyecto bajo un nuevo eks  cluster name  eks-observability-v2
Se optimizan nodos para evitar sobre costo en cuenta aws personal
Se soluciona problema de compatibilidad en grafanna alloy y se expone por medio de aws prometeus hacia grafana UI por medio de ingress.


---

## 🌐 URLs de Acceso

### Aplicación Hello World
**URL:** http://k8s-appdemo-hellowor-6ac75a7fca-1457236690.us-east-1.elb.amazonaws.com

### Grafana UI
**URL:** http://k8s-observab-grafana-536238b7ca-1103291513.us-east-1.elb.amazonaws.com

**Credenciales:**
- Usuario: `admin`
- Password: `admin123`

### Amazon Managed Prometheus
**Workspace ID:** ws-1c2bc642-d761-4c63-a58e-e12da54d36f1  
**Región:** us-east-1  
**Endpoint:** https://aps-workspaces.us-east-1.amazonaws.com/workspaces/ws-1c2bc642-d761-4c63-a58e-e12da54d36f1/

-

### 2. Configurar kubeconfig
```bash
aws eks update-kubeconfig --name eks-observability-v2 --region us-east-1
```

### 3. Desplegar Grafana Alloy
```bash
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update
helm install grafana-alloy grafana/alloy -n observability -f alloy-final-values.yaml
```

### 4. Desplegar Grafana
```bash
helm repo add grafana https://grafana.github.io/charts
helm install grafana grafana/grafana -n observability -f grafana-values.yaml
kubectl apply -f grafana-ingress.yaml
```

### 5. Verificar Despliegue
```bash
# Verificar todos los pods
kubectl get pods -A

# Verificar Ingress
kubectl get ingress -A

# Verificar logs de Alloy
kubectl logs -n observability -l app.kubernetes.io/name=alloy -c alloy --tail=50
```
Tomado de https://grafana.com/docs/alloy/latest/configure/kubernetes/
---

## 📊 Información del Cluster

**Nombre:** eks-observability-v2  
**Versión:** 1.29  
**Región:** us-east-1  
**VPC CIDR:** 10.0.0.0/16  
**Account ID:** 905418343592  
**OIDC Provider:** FD2B7A8AB4911A4FF83F2933038345AB

**Nodos:**
- Bootstrap: 1x t3.medium (managed node group)
- Karpenter: Dinámico (t3.medium, t3.large)

**Componentes Principales:**
- ✅ AWS Load Balancer Controller (v2.17.1)
- ✅ Karpenter (v0.37.0)
- ✅ Grafana Alloy (DaemonSet)
- ✅ Grafana (Deployment)
- ✅ Amazon Managed Prometheus
- ✅ External Secrets Operator

---

## 📝 Notas Importantes

1. **Persistencia de Grafana:** Deshabilitada (sin EBS CSI driver). Los dashboards/configuraciones se pierden al reiniciar el pod.
2. **Costos:** Recursos desplegados generan costos en AWS (EKS, EC2, NAT Gateway, ALB, AMP).
3. **Seguridad:** Endpoints públicos restringidos a IP específica (181.53.12.236/32) en `allowed_cidrs`.
4. **Retención AMP:** 150 días por defecto.
5. **Karpenter:** Consolida nodos automáticamente si utilización < 50%.

---

## 🔒 Seguridad y RBAC

### Roles configurados:
- **cluster-admin:** Acceso completo al cluster
- **developer:** Acceso limitado a namespace `developer-ns` (view, create pods/deployments)

### IAM Roles (IRSA):
- `KarpenterController-*` — Karpenter node provisioning
- `ALBControllerRole-*` — ALB/NLB management
- `GrafanaAlloyRole-*` — AMP remote_write
- `AppDemoRole-*` — Secrets Manager access
- `ExternalSecretsRole-*` — Secrets Manager sync

---

## 📚 Referencias tomadas para realizar prueba

- [Amazon EKS Best Practices](https://aws.github.io/aws-eks-best-practices/)
- [Karpenter Documentation](https://karpenter.sh/)
- [Grafana Alloy Documentation](https://grafana.com/docs/alloy/)
- [Amazon Managed Prometheus](https://aws.amazon.com/prometheus/)
- [AWS Load Balancer Controller](https://kubernetes-sigs.github.io/aws-load-balancer-controller/)

Guía técnica detallada de despliegue de infraestructura, cluster EKS y componentes de observabilidad en AWS, automatizado con Terraform.

El siguiente documento expone la consecucion de hitos y su integracion tecnica hacia aws (eks,aws console) y como se despliega desde terraform IAC.

 📋 Vista General del Cluster 

A continuacion se describen de manera general  los componentes mas importantes del data plane :

### Namespaces esperados en el cluster:
PS C:\Users\cpuo\Observability_test> kubectl get namespaces
NAME                      STATUS   AGE
app-demo                  Active   5h
default                   Active   34h
developer-ns              Active   5h
external-secrets-system   Active   4h47m
karpenter                 Active   33h
kube-node-lease           Active   34h
kube-public               Active   34h
kube-system               Active   34h
observability             Active   5h
PS C:\Users\cpuo\Observability_test> 

 Descripcion 
1. **`kube-system`** — Componentes core de Kubernetes (DNS, proxy de red).
2. **`kube-public`** — Recursos públicos de lectura.
3. **`default`** — Namespace por defecto.
4. **`observability`** — Grafana Alloy y componentes de monitoreo.
5. **`karpenter`** — Controller de Karpenter para node provisioning.
6. **`kube-node-lease`** — Heartbeats de nodos.
7. **`app-demo`** — Aplicación Hello World y su ESO/CSI.
8. **`external-secrets-system`** — ESO controller.
9. **`istio-system`** (opcional) — Control plane y gateways de Istio.



### Pods esperados por namespace (resumen):

| Namespace | Pod/Componente | Tipo | Cantidad | Descripción |
|-----------|----------------|------|----------|-------------|
| `kube-system` | coredns | Deployment | 2 | Resolución DNS |
| `kube-system` | aws-node | DaemonSet | N* | Plugin CNI de AWS (un pod por nodo) |
| `kube-system` | kube-proxy | DaemonSet | N* | Proxy de red (un pod por nodo) |
| `observability` | grafana-alloy | DaemonSet | N* | Agent de observabilidad (un pod por nodo) |
| `observability` | kube-state-metrics | Deployment | 1 | Exportador de estado de Kubernetes |
| `observability` | prometheus-node-exporter | DaemonSet | N* | Métricas del nodo (CPU, memoria, disco) |
| `karpenter` | karpenter | Deployment | 1 | Controller de provisioning de nodos |
| `app-demo` | hello-world | Deployment | 1-3 | Aplicación demo (stateless, escalable) |
| `app-demo` | external-secrets | Deployment | 1 | ESO controller (opcional si no se usa CSI) |
| `external-secrets-system` | external-secrets | Deployment | 1 | ESO controller (instalación dedicada) |
| `istio-system` | istiod | Deployment | 1 | Control plane de Istio (opcional) |
| `istio-system` | istio-ingressgateway | Deployment | 1 | Ingress gateway de Istio (opcional) |

*\*N = número de nodos en el cluster.*

**Total esperado: 12-20+ pods** (dependiendo de réplicas y si Istio está habilitado).

### Nodos a nivel cluster (resumen):

PS C:\Users\cpuo\Observability_test> kubectl get nodes     
NAME                         STATUS   ROLES    AGE   VERSION
ip-10-0-1-163.ec2.internal   Ready    <none>   29h   v1.29.15-eks-ecaa3a6
ip-10-0-2-232.ec2.internal   Ready    <none>   30h   v1.29.15-eks-ecaa3a6

Cada nodo ejecuta:
- `aws-node` (plugin CNI).
- `kube-proxy`.
- `grafana-alloy` (DaemonSet).
- `prometheus-node-exporter` (opcional).
- Pods de aplicación (`hello-world`, controllers, etc.).

---

---

## HITO 1: Infraestructura Base (VPC + EKS)


Crear la infraestructura base: VPC multi-AZ, subnets públicas/privadas, NAT Gateway e inicializar cluster EKS administrado con endpoint API restringido,configuracion de dos tipos de roles para la administracion general del cluster

### Integración con AWS
- **VPC:** Red aislada 10.0.0.0/16 con 3 AZs.
  - Subnets públicas (10.0.101.0/24, 10.0.102.0/24, 10.0.103.0/24) para ALB.
  - Subnets privadas (10.0.1.0/24, 10.0.2.0/24, 10.0.3.0/24) para nodos y pods.
  - NAT Gateway en cada AZ para egress de pods.
  - Internet Gateway para acceso público.
- **Security Groups:** Controlar tráfico entre subnets, nodos y ALB.
- **IAM Roles:** Rol para nodos de EKS (asume rol de EC2), OIDC provider para IRSA.
- **EKS:** Clúster administrado (control plane gestionado por AWS, API server privado o restringido).

### Integración con EKS
- Cluster EKS se crea con endpoint `private_access = true` y `public_access_cidrs` limitados.
- Se configura `aws-auth` ConfigMap para mapear usuarios/roles IAM a RBAC de Kubernetes.
- Se crean RoleBindings iniciales: `cluster-admin` para usuarios administrativos, `view-only` para developers.

### Despliegue con Terraform
- **Módulo:** `terraform/modules/network` (o en `main.tf` si no hay módulos).
- **Ubicación:** `terraform/main.tf` (recursos VPC, subnets, route tables, NAT).
- **Recursos clave:**
  - `aws_vpc` — VPC principal.
  - `aws_subnet` — Subnets públicas y privadas (6 totales, 2-3 por AZ).
  - `aws_nat_gateway` — 1 por AZ (3 totales) para egress.
  - `aws_internet_gateway` — Acceso público.
  - `aws_eks_cluster` — Clúster EKS.
  - `aws_iam_role` — Rol para nodos y control plane.
  - `aws_iam_openid_connect_provider` — OIDC provider para IRSA.

### Componentes en el Cluster (resultado del Hito 1)
**Namespaces:** `kube-system`, `kube-public`, `default`.

**Pods auto-creados por EKS:**
- `coredns` (2 replicas en `kube-system`) — Resolución DNS.
- `aws-node` DaemonSet (N pods en `kube-system`) — Plugin CNI de AWS.
- `kube-proxy` DaemonSet (N pods en `kube-system`) — Proxy de red.

**Nodos:** 2-3 nodos iniciales (EC2) en subnets privadas.

**Recursos de RBAC:**
- `aws-auth` ConfigMap con mapeo de usuarios/roles IAM.
- ClusterRoles y ClusterRoleBindings para admin y developer.

---

## HITO 2: Gestión de Nodos (Karpenter)

### Objetivo
Reemplazar el node autoscaler tradicional (Cluster Autoscaler) con Karpenter, que provisiona nodos dinámicamente según demanda de pods con políticas declarativas.

### Integración con AWS
- **EC2 API:** Karpenter llama a `ec2:RunInstances`, `ec2:TerminateInstances`, `ec2:Describe*` para crear/destruir instancias.
- **IAM Role (IRSA):** ServiceAccount `karpenter` anotado con rol que tiene permisos EC2 mínimos.
- **Subnets y Security Groups:** Karpenter lanza nodos en subnets privadas etiquetadas con `karpenter.sh/discovery: <cluster-name>`.
- **Tags:** Karpenter etiqueta instancias con `kubernetes.io/cluster/<name>: owned` para que EKS las reconozca.

### Integración con EKS
- **Namespace:** `karpenter` (creado por Helm).
- **ServiceAccount:** `karpenter` anotado con `eks.amazonaws.com/role-arn: arn:aws:iam::...role/KarpenterNodeRole`.
- **CRD:** `Provisioner` — declarativo, configura tipos de instancia, subnets, consolidación y TTL.
- **Pods:**
  - `karpenter-controller` (Deployment, 1 replica) — Reconciler que monitorea pod requests y provisiona nodos.
  - `karpenter-webhook` (Deployment, 1 replica) — Webhook para validar manifiestos.

### Despliegue con Terraform
- **Módulo:** `terraform/modules/karpenter` (o integrado en `main.tf`).
- **Ubicación:** `terraform/main.tf` o `terraform/karpenter.tf`.
- **Recursos clave:**
  - `aws_iam_role` — Rol KarpenterNodeRole (asume role desde EKS OIDC).
  - `aws_iam_role_policy` — Permisos EC2 para Karpenter.
  - `helm_release` — Chart de Karpenter (repo `oci://public.ecr.aws/karpenter`).
  - `kubernetes_namespace` — Namespace `karpenter`.
  - `kubernetes_manifest` — Provisioner CRD.

### Componentes en el Cluster (resultado del Hito 2)
**Namespace:** `karpenter`.

**Pods:**
- `karpenter-controller` (Deployment, 1 replica).
- `karpenter-webhook` (Deployment, 1 replica).

PS C:\Users\cpuo\Observability_test\terraform> kubectl get pods -n karpenter
NAME                         READY   STATUS    RESTARTS   AGE
karpenter-675bc46c6d-kj5n9   1/1     Running   0          3m52s
karpenter-675bc46c6d-vmrnm   1/1     Running   0          3m52s

**CRDs:**
- `Provisioner` — Política de node provisioning.
- `AWSNodeTemplate` — Template de nodos EC2.

**Nodos dinámicos:** Karpenter agrega nodos según demanda; ejemplos:
- Si se solicita 1 GiB RAM, Karpenter lanza 1 nodo `t3.medium`.
- Si hay menos de 10% utilización, Karpenter consolida/termina nodos.

**Total de pods Karpenter: 2 (controller + webhook).**

---

## HITO 3: Observabilidad (Grafana Alloy + Amazon Managed Prometheus)

### Objetivo
Implementar stack completo de observabilidad con Grafana Alloy (recolección), Amazon Managed Prometheus (almacenamiento) y Grafana (visualización), permitiendo monitorear el cluster EKS en tiempo real.

### ¿Por qué Amazon Managed Prometheus (AMP)?

**Ventajas de AMP vs Prometheus auto-gestionado:**

1. **Sin Overhead Operacional**
   - No requiere gestionar servidores, storage, backups ni HA
   - AWS maneja escalado automático, durabilidad y disponibilidad
   - Sin preocupaciones por dimensionamiento de disco o retención

2. **Integración Nativa con AWS**
   - Autenticación SigV4 (sin gestión de tokens o passwords)
   - IRSA (IAM Roles for Service Accounts) - permisos granulares por pod
   - Integración con CloudWatch, X-Ray y otros servicios AWS

3. **Costo-Eficiencia**
   - Pago por uso (ingesta + almacenamiento + queries)
   - No requiere instancias EC2 dedicadas 24/7 para Prometheus
   - Retención hasta 150 días sin gestión de storage

4. **Escalabilidad**
   - Soporta millones de métricas activas sin tunning
   - Query performance optimizado por AWS
   - Compatible con PromQL estándar

5. **Seguridad y Compliance**
   - Cifrado en tránsito y reposo por defecto
   - VPC endpoints para tráfico privado (opcional)
   - AWS CloudTrail para auditoría de accesos

### Integración con AWS
- **Amazon Managed Prometheus (AMP):** Workspace dedicado para el cluster.
  - **Workspace ID:** `ws-1c2bc642-d761-4c63-a58e-e12da54d36f1`
  - **Endpoint:** `https://aps-workspaces.us-east-1.amazonaws.com/workspaces/ws-1c2bc642-d761-4c63-a58e-e12da54d36f1/`
  - **Remote Write:** `https://aps-workspaces.us-east-1.amazonaws.com/workspaces/ws-1c2bc642-d761-4c63-a58e-e12da54d36f1/api/v1/remote_write`
  - Autenticación: SigV4 (firma con credenciales AWS temporales).
  - Estado: `ACTIVE`
  - Región: `us-east-1`
  
- **IAM Role (IRSA):** Rol específico para Alloy con permiso `aps:RemoteWrite` al workspace AMP.
  - **Rol:** `GrafanaAlloyRole-eks-observability-v2`
  - **Policy:** `AMPWritePolicy` (inline) con permisos `aps:RemoteWrite`
  - **Trust Policy:** Confía en OIDC provider del cluster con condición `system:serviceaccount:observability:grafana-alloy`

- **IAM Role para Grafana:** Rol para consultar métricas de AMP (lectura).
  - **Autenticación:** SigV4 automática vía AWS SDK en datasource

### Integración con EKS
- **Namespace:** `observability` (creado por Terraform/Helm).

#### Grafana Alloy (Recolección de Métricas)

- **ServiceAccount:** `grafana-alloy` anotado con `eks.amazonaws.com/role-arn` para IRSA.
- **DaemonSet:** `grafana-alloy` — 1 pod por nodo, recolecta métricas locales.
  - **Imagen:** `grafana/alloy:latest`
  - **Configuración:** Scraping de kubelet, cAdvisor, kube-apiserver y pods anotados
  - **Remote Write:** Envía métricas a AMP con SigV4
  - **Clustering:** Habilitado para evitar duplicados en scraping de targets centrales

**Configuración de Alloy (alloy-final-values.yaml):**
- **Scrape Jobs:**
  1. `kubelet` — Métricas de runtime de contenedores
  2. `cadvisor` — Métricas de uso de CPU/memoria/red por contenedor
  3. `kube_apiserver` — Métricas del API server (request rate, latency)
  4. `kubernetes_pods` — Pods con annotation `prometheus.io/scrape=true`

- **Discovery:** `discovery.kubernetes` para auto-descubrimiento de nodos/endpoints/pods
- **Authentication:** SigV4 con región `us-east-1` en remote_write
- **Queue Config:** `max_shards=200`, `capacity=10000` para buffering

#### Grafana (Visualización)

- **Deployment:** `grafana` (1 replica) — UI web para consultar y visualizar métricas
  - **Imagen:** `grafana/grafana:latest`
  - **Credenciales:** 
    - Usuario: `admin`
    - Password: `admin123`
  - **Datasource:** Amazon Managed Prometheus pre-configurado con SigV4
  - **Persistencia:** Deshabilitada (sin EBS CSI driver instalado)

- **Service:** ClusterIP (interno)
- **Ingress:** ALB Ingress para acceso público
  - **URL:** http://k8s-observab-grafana-536238b7ca-1103291513.us-east-1.elb.amazonaws.com
  - **Health Check:** `/api/health`
  - **Esquema:** internet-facing
  - **Target Type:** IP (apunta directamente a pods)

### Despliegue con Terraform
- **Módulo:** `terraform/modules/observability` (o integrado en `main.tf`).
- **Ubicación:** `terraform/main.tf` o `terraform/observability.tf`.
- **Recursos clave:**
  - `module.prometheus` — Terraform module para crear AMP workspace
  - `data.aws_prometheus_workspace` — Data source para obtener detalles del workspace
  - `aws_iam_role.grafana_alloy` — Rol IRSA para Alloy
  - `aws_iam_role_policy.amp_write` — Policy inline con `aps:RemoteWrite`
  - `kubernetes_service_account.grafana_alloy` — ServiceAccount anotado con role ARN
  - `kubernetes_namespace.observability` — Namespace dedicado

**Nota:** Alloy y Grafana se despliegan manualmente via Helm debido a limitaciones del provider Kubernetes con configuración compleja:

```bash
# Despliegue de Grafana Alloy
helm install grafana-alloy grafana/alloy -n observability \
  -f terraform/alloy-final-values.yaml

# Despliegue de Grafana
helm install grafana grafana/grafana -n observability \
  -f terraform/grafana-values.yaml

# Aplicar Ingress de Grafana
kubectl apply -f terraform/grafana-ingress.yaml
```

### Componentes en el Cluster (resultado del Hito 3)
**Namespace:** `observability`.

**Pods:**
```
NAME                       READY   STATUS    RESTARTS   AGE
grafana-alloy-2z7rf        2/2     Running   0          4h
grafana-alloy-xxxxx        2/2     Running   0          4h
grafana-6945894fdd-qhh9d   1/1     Running   0          15m
```

- **grafana-alloy** DaemonSet (N replicas, 1 por nodo) — Recolector de métricas
  - Container 1: `alloy` — Agente principal
  - Container 2: `config-reloader` — Recarga configuración automática
- **grafana** Deployment (1 replica) — UI de visualización

**Services:**
- `grafana` (ClusterIP) — Acceso interno al UI

**Ingress:**
- `grafana` (ALB) — Acceso público al UI

**Integración AWS:**
1. Alloy asume rol `GrafanaAlloyRole-eks-observability-v2` vía IRSA
2. Firma requests HTTP a AMP con SigV4 (credenciales temporales)
3. Envía métricas cada 15s a remote_write endpoint
4. AMP almacena métricas con retención de 150 días
5. Grafana consulta AMP usando SigV4 (autenticación automática con AWS SDK)

### Acceso a Grafana

**URL:** http://k8s-observab-grafana-536238b7ca-1103291513.us-east-1.elb.amazonaws.com

**Credenciales:**
- Usuario: `admin`
- Password: `admin123`

**Datasource Pre-configurado:**
- Nombre: `Amazon Managed Prometheus`
- Tipo: `Prometheus`
- URL: `https://aps-workspaces.us-east-1.amazonaws.com/workspaces/ws-1c2bc642-d761-4c63-a58e-e12da54d36f1`
- Autenticación: SigV4 (región: us-east-1)
- Estado: Activo


## HITO 4: Aplicación Demo & Networking (ALB + Ingress)

### Objetivo
Desplegar aplicación Hello World (Nginx) como Deployment stateless, exponerla vía AWS Load Balancer (ALB) usando Ingress, y asegurar health checks y escalado.

### Integración con AWS
- **ALB (Application Load Balancer):** AWS Load Balancer Controller convierte recursos Ingress en ALB en AWS.
  - Listener en puerto 80/443.
  - Target Group con pods de `hello-world` (IP targets).
  - Health checks: HTTP GET `/` puerto 80.
- **IAM Role (IRSA):** Controller requiere rol con permisos `elbv2:*`, `ec2:Describe*`, `iam:PassRole`.
- **Security Groups:** Abiertos entre ALB (public subnet) y nodos (private subnet).

### Integración con EKS
- **Namespace:** `app-demo`.
- **ServiceAccount:** `app-demo-sa` anotado con rol IRSA (si consume secretos de AWS).
- **Deployment:** `hello-world` (1-3 replicas, escalable).
  - Readiness probe: HTTP GET `/` con delay 5s.
  - Liveness probe: HTTP GET `/health` con delay 10s.
  - Requests: CPU 100m, Memory 128Mi.
  - Limits: CPU 250m, Memory 256Mi.
- **Service:** `hello-world` (ClusterIP) para comunicación intra-cluster.
- **Ingress:** `hello-world-ingress` anotado con ALB controller settings.
- **AWS Load Balancer Controller:** Deployment en `kube-system` (1 replica) que gestiona Ingress ↔ ALB.

### Despliegue con Terraform
- **Módulo:** `terraform/modules/alb_controller` y `terraform/modules/app_demo`.
- **Ubicación:** `terraform/main.tf` o `terraform/app-demo.tf`.
- **Recursos clave:**
  - `aws_iam_role` — Rol para ALB Controller (IRSA).
  - `aws_iam_role_policy` — Permisos ELBv2 y EC2.
  - `helm_release` — Chart AWS Load Balancer Controller (repo `https://aws.github.io/eks-charts`).
  - `kubernetes_namespace` — Namespace `app-demo`.
  - `kubernetes_deployment` — Hello World Deployment.
  - `kubernetes_service` — Service hello-world.
  - `kubernetes_ingress` — Ingress hello-world-ingress.

**Ingress manifiesto (en Terraform o `examples/ingress-hello-world.yaml`):**
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: hello-world-ingress
  namespace: app-demo
  annotations:
    kubernetes.io/ingress.class: alb
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/healthcheck-path: /
    alb.ingress.kubernetes.io/healthcheck-interval-seconds: "30"
spec:
  rules:
  - http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: hello-world
            port:
              number: 80
```

**Hello World Deployment (en Terraform o `examples/deployment-hello-world.yaml`):**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hello-world
  namespace: app-demo
spec:
  replicas: 2
  selector:
    matchLabels:
      app: hello-world
  template:
    metadata:
      labels:
        app: hello-world
    spec:
      serviceAccountName: app-demo-sa
      containers:
      - name: nginx
        image: nginx:alpine
        ports:
        - containerPort: 80
        readinessProbe:
          httpGet:
            path: /
            port: 80
          initialDelaySeconds: 5
          periodSeconds: 10
        livenessProbe:
          httpGet:
            path: /health
            port: 80
          initialDelaySeconds: 10
          periodSeconds: 20
        resources:
          requests:
            cpu: "100m"
            memory: "128Mi"
          limits:
            cpu: "250m"
            memory: "256Mi"
        env:
        - name: APP_NAME
          value: "hello-world"
```

### Componentes en el Cluster (resultado del Hito 4)
**Namespace:** `app-demo`.

**Pods:**
- `hello-world` Deployment (2-3 replicas, escalable con HPA) — Aplicación Nginx.
- `aws-load-balancer-controller` Deployment en `kube-system` (1 replica) — Controller de ALB.

**Kubernetes Resources:**
- Service `hello-world` (ClusterIP).
- Ingress `hello-world-ingress` (convierte en ALB).

**AWS Resources (auto-creados por ALB Controller):**
- ALB en subnets públicas.
- Target Group con pods de hello-world.
- Listener HTTP 80 → Target Group.

**Integración:**
- Cliente → ALB (public subnet) → Ingress Controller → hello-world pods (private subnet).
- Alloy scrapea métricas de hello-world en namespace `app-demo`.

**Total de pods app-demo: 2-3 (hello-world replicas).**

---

## HITO 5: Gestión de Secretos (ESO + Secrets Manager)

### Objetivo
Sincronizar secretos desde AWS Secrets Manager al cluster usando External Secrets Operator (ESO) o Secrets Store CSI Driver, sin exponer credenciales en código.

### Integración con AWS
- **AWS Secrets Manager:** Almacena secretos (API keys, passwords, DB credentials).
  - Secreto ejemplo: `eks-observability-app-secret` con propiedades (API_KEY, DB_PASSWORD, etc.).
- **IAM Role (IRSA):** Rol ESO con permiso `secretsmanager:GetSecretValue` y `kms:Decrypt` (si usa KMS).
- **KMS (opcional):** Cifrado de secretos en reposo.
- **Audit (CloudTrail):** Registra acceso a secretos para compliance.

### Integración con EKS
- **Namespace:** `external-secrets-system` (o `app-demo` si se coloca ESO ahí).
- **ServiceAccount:** `external-secrets` anotado con rol IRSA.
- **Controllers:**
  - `external-secrets-controller` (Deployment, 1 replica) — Sincroniza secretos.
  - `external-secrets-webhook` (Deployment, 1 replica) — Valida manifiestos.
- **CRDs:**
  - `SecretStore` — Configuración de provider AWS Secrets Manager.
  - `ExternalSecret` — Declara qué secreto sincronizar desde AWS y a dónde en K8s.
- **Resultado:** Kubernetes Secrets creados dinámicamente y sincronizados cada 15-30s.

### Despliegue con Terraform
- **Módulo:** `terraform/modules/external_secrets`.
- **Ubicación:** `terraform/main.tf` o `terraform/external-secrets.tf`.
- **Recursos clave:**
  - `aws_iam_role` — Rol ESO para IRSA.
  - `aws_iam_role_policy` — Permisos Secrets Manager y KMS.
  - `helm_release` — Chart External Secrets (repo `https://external-secrets.github.io/kubernetes-external-secrets/`).
  - `kubernetes_namespace` — Namespace `external-secrets-system`.
  - `kubernetes_manifest` — SecretStore y ExternalSecret (si se gestionan en K8s).

**SecretStore manifiesto (en `examples/secretstore-externalsecret.yaml` o Terraform):**
```yaml
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
metadata:
  name: aws-secretsmanager
  namespace: app-demo
spec:
  provider:
    aws:
      service: SecretsManager
      region: us-east-1
      auth:
        jwt:
          serviceAccountRef:
            name: external-secrets
```

**ExternalSecret manifiesto (en `examples/`):**
```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: app-secret-external
  namespace: app-demo
spec:
  refreshInterval: 15s
  secretStoreRef:
    name: aws-secretsmanager
    kind: SecretStore
  target:
    name: app-secret
    creationPolicy: Owner
  data:
  - secretKey: API_KEY
    remoteRef:
      key: eks-observability-app-secret
      property: API_KEY
  - secretKey: DB_PASSWORD
    remoteRef:
      key: eks-observability-app-secret
      property: DB_PASSWORD
```

### Componentes en el Cluster (resultado del Hito 5)
**Namespace:** `external-secrets-system`.

**Pods:**
- `external-secrets-controller` Deployment (1 replica) — Sincronizador de secretos.
- `external-secrets-webhook` Deployment (1 replica) — Validador.

**Kubernetes Resources:**
- `SecretStore` en `app-demo` — Configuración de proveedor AWS.
- `ExternalSecret` en `app-demo` — Declaración de qué sincronizar.
- `Secret` en `app-demo` (auto-creado) — Secreto sincronizado desde AWS.

**Integración AWS:**
- ESO controller asume rol IAM vía IRSA.
- Cada 15s, ESO llama a `secretsmanager:GetSecretValue` para obtener valor actual.
- Si cambia en Secrets Manager, K8s Secret se actualiza automáticamente.

**Consumo en App:**
- Hello World Deployment monta Secret como variables de entorno o volúmenes.

**Total de pods ESO: 2 (controller + webhook).**

---

---

## 📊 Resumen de Componentes Totales en el Cluster

### Namespaces (9):
1. `kube-system`
2. `kube-public`
3. `default`
4. `observability`
5. `karpenter`
6. `kube-node-lease`
7. `app-demo`
8. `external-secrets-system`
9. `istio-system` (opcional)


### Validación post-despliegue:
```bash
# Verificar namespaces
kubectl get namespaces

# Verificar pods en cada namespace
kubectl get pods --all-namespaces

# Verificar nodos
kubectl get nodes

# Verificar servicios y Ingress
kubectl get svc,ingress -A

# Verificar que Alloy está enviando a AMP
kubectl logs -n observability daemonset/grafana-alloy -c alloy --tail=50
```

---

## 📝 Estructura de Carpetas Terraform Recomendada

```
terraform/
├── main.tf                 # Hito 1 (VPC, EKS, IAM base)
├── karpenter.tf           # Hito 2 (Karpenter, Provisioner)
├── observability.tf       # Hito 3 (Alloy, AMP, kube-state-metrics)
├── alb-app-demo.tf       # Hito 4 (ALB Controller, Hello World)
├── external-secrets.tf    # Hito 5 (ESO, SecretStore, ExternalSecret)
├── providers.tf           # Providers (AWS, Kubernetes, Helm)
├── variables.tf           # Variables (cluster name, region, etc.)
├── outputs.tf             # Outputs (ALB DNS, AMP workspace ID, etc.)
├── terraform.tfvars       # Valores específicos por entorno
└── modules/
    ├── network/          # VPC, subnets, NAT, IGW
    ├── eks/              # EKS cluster, control plane
    ├── karpenter/        # Karpenter role, policy, Provisioner
    ├── observability/    # Alloy, AMP, kube-state-metrics
    ├── alb_controller/   # ALB Controller role, policy, helm
    ├── app_demo/         # Hello World deployment, service, ingress
    └── external_secrets/ # ESO role, policy, helm, SecretStore
```

