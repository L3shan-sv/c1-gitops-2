resource "helm_release" "vault" {
  name             = "vault"
  repository       = "https://helm.releases.hashicorp.com"
  chart            = "vault"
  version          = "0.27.0"
  namespace        = "vault"
  create_namespace = true

  values = [
    yamlencode({
      server = {
        ha = {
          # HA mode with 3 replicas in prod — single replica in dev/staging.
          enabled  = var.environment == "prod"
          replicas = var.environment == "prod" ? 3 : 1
          raft = {
            enabled = true # Raft integrated storage — no external Consul needed.
          }
        }
        serviceAccount = {
          annotations = {
            "eks.amazonaws.com/role-arn" = var.vault_irsa_role_arn
          }
        }
        # Audit logging — every Vault operation is logged.
        auditStorage = {
          enabled = true
          size    = "10Gi"
        }
      }
      injector = {
        # The Vault Agent Sidecar Injector watches for pod annotations
        # and injects a Vault agent sidecar that retrieves secrets at pod start.
        enabled = true
      }
    })
  ]
}

# Vault Kubernetes auth backend — allows pods to authenticate to Vault
# using their Kubernetes ServiceAccount token.
resource "vault_auth_backend" "kubernetes" {
  type = "kubernetes"
  depends_on = [helm_release.vault]
}

resource "vault_kubernetes_auth_backend_config" "main" {
  backend            = vault_auth_backend.kubernetes.path
  kubernetes_host    = var.cluster_endpoint
  kubernetes_ca_cert = var.cluster_ca_cert
}

# Vault policy for the myapp role.
resource "vault_policy" "myapp" {
  name = "myapp"
  policy = <<EOT
path "secret/data/myapp/*" {
  capabilities = ["read"]
}
EOT
}

resource "vault_kubernetes_auth_backend_role" "myapp" {
  backend                          = vault_auth_backend.kubernetes.path
  role_name                        = "myapp"
  bound_service_account_names      = ["myapp"]
  bound_service_account_namespaces = ["dev", "staging", "prod"]
  token_policies                   = [vault_policy.myapp.name]
  token_ttl                        = 3600
}
