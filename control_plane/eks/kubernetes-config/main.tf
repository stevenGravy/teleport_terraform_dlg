# defines aws provider
provider "aws" {
  region = var.region
}

# sources information about an eks cluster based on its name
data "aws_eks_cluster" "cluster" {
  name = var.cluster_name
}

# sources auth token for eks cluster
data "aws_eks_cluster_auth" "cluster" {
  name = var.cluster_name
}

# local variables
locals {
  tags = {
    ManagedBy = "terraform"
    owner     = var.user
    env       = "dev"
  }
}

# defines k8s provider and auth
provider "kubernetes" {
  host                   = data.aws_eks_cluster.cluster.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.cluster.token
}

# defines helm provieer and auth 
provider "helm" {
  kubernetes {
    host                   = data.aws_eks_cluster.cluster.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority[0].data)
    token                  = data.aws_eks_cluster_auth.cluster.token
  }
}

# creates k8s config file for cluster
resource "local_sensitive_file" "kubeconfig" {
  content = templatefile("${path.module}/kubeconfig.tpl", {
    cluster_name = var.cluster_name,
    clusterca    = data.aws_eks_cluster.cluster.certificate_authority[0].data,
    endpoint     = data.aws_eks_cluster.cluster.endpoint,
  })
  filename = "./kubeconfig-${var.cluster_name}"
}

# creates ent license as k8s secret
resource "kubernetes_secret" "license" {
  metadata {
    name      = "license"
    namespace = kubernetes_namespace.teleport_cluster.metadata[0].name
  }

  data = {
    # the path module creates a . so only one . is appended to it which inferes .. (the dir above)
    "license.pem" = file("${path.module}./license.pem")
  }

  type = "Opaque"
}

# creates namespace for teleport cluster per https://goteleport.com/docs/ver/15.x/deploy-a-cluster/helm-deployments/kubernetes-cluster/#install-the-teleport-cluster-helm-chart
resource "kubernetes_namespace" "teleport_cluster" {
  metadata {
    name = "teleport-cluster"
    labels = {
      "pod-security.kubernetes.io/enforce" = "baseline"
    }
  }
}

# defines helm release for teleport cluster
# teleport k8s operator is added via the operator.enabled arugmenet in the values section below
resource "helm_release" "teleport_cluster" {
  namespace = kubernetes_namespace.teleport_cluster.metadata[0].name
  wait      = true
  timeout   = 300

  name = "teleport-cluster"

  repository = "https://charts.releases.teleport.dev"
  chart      = "teleport-cluster"
  version    = var.teleport_ver
  values = [
    <<EOF
clusterName: "v16.${var.domain_name}"
proxyListenerMode: multiplex
acme: true
acmeEmail: "${var.email}"
enterprise: true
operator:
  enabled: true
EOF
  ]
}

# sources the k8s service for refernece (may be removed in future release)
data "kubernetes_service" "teleport_cluster" {
  metadata {
    name      = helm_release.teleport_cluster.name
    namespace = helm_release.teleport_cluster.namespace
  }
}

# used for creating subdomain on existing zone. zone is defined by the variable domain_name
data "aws_route53_zone" "main" {
  name = var.domain_name
}

# creates DNS record for teleport cluster on eks
resource "aws_route53_record" "cluster_endpoint" {
  zone_id    = data.aws_route53_zone.main.zone_id
  name       = "v16.${var.domain_name}"
  type       = "CNAME"
  ttl        = "300"
  records    = [data.kubernetes_service.teleport_cluster.status[0].load_balancer[0].ingress[0].hostname]
}

# creates wildcard record for teleport cluster on eks 
resource "aws_route53_record" "wild_cluster_endpoint" {
  zone_id    = data.aws_route53_zone.main.zone_id
  name       = "*.v16.${var.domain_name}"
  type       = "CNAME"
  ttl        = "300"
  records    = [data.kubernetes_service.teleport_cluster.status[0].load_balancer[0].ingress[0].hostname]
}