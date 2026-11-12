output "cluster_name" {
  description = "EKS cluster name."
  value       = module.eks.cluster_name
}

output "region" {
  description = "AWS region."
  value       = var.region
}

output "node_availability_zone" {
  description = "AZ that hosts the blockchain node group and its EBS volumes."
  value       = local.azs[var.node_az_index]
}

output "configure_kubectl" {
  description = "Command to point kubectl at the cluster."
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}

output "grafana_admin_password" {
  description = "Grafana admin password (user: admin)."
  value       = random_password.grafana_admin.result
  sensitive   = true
}
