################################################################################
# Prometheus, Alertmanager and Grafana. Prometheus selects every ServiceMonitor
# and PrometheusRule in the cluster, so the node's monitors in ../k8s are picked
# up without extra labels.
################################################################################

resource "random_password" "grafana_admin" {
  length  = 24
  special = false
}

resource "helm_release" "kube_prometheus_stack" {
  namespace        = "monitoring"
  create_namespace = true
  name             = "kube-prometheus-stack"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  version          = var.kube_prometheus_stack_version
  timeout          = 900

  values = [
    yamlencode({
      prometheus = {
        prometheusSpec = {
          serviceMonitorSelectorNilUsesHelmValues = false
          podMonitorSelectorNilUsesHelmValues     = false
          ruleSelectorNilUsesHelmValues           = false
          retention                               = "7d"
          nodeSelector                            = { "node-role" = "general" }
        }
      }
      alertmanager = {
        alertmanagerSpec = {
          nodeSelector = { "node-role" = "general" }
        }
      }
      grafana = {
        adminPassword = random_password.grafana_admin.result
        nodeSelector  = { "node-role" = "general" }
      }
    })
  ]

  depends_on = [module.eks]
}
