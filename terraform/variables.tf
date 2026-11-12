variable "region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-2"
}

variable "cluster_name" {
  description = "Name of the EKS cluster and prefix for related resources."
  type        = string
  default     = "stateful-node"
}

variable "kubernetes_version" {
  description = "EKS Kubernetes version."
  type        = string
  default     = "1.31"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.30.0.0/16"
}

variable "api_allowed_cidrs" {
  description = "CIDRs allowed to reach the public EKS API endpoint. Restrict this to your own IP."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "system_instance_types" {
  description = "Instance types for the general node group (CoreDNS, Prometheus, Grafana)."
  type        = list(string)
  default     = ["m6i.large"]
}

variable "node_instance_types" {
  description = "Instance types for the dedicated blockchain node group. The execution client needs roughly 16 GiB of memory during sync."
  type        = list(string)
  default     = ["m6i.2xlarge"]
}

variable "node_az_index" {
  description = "Index of the AZ (and private subnet) that hosts the blockchain node group. EBS volumes are zonal, so the node and its volumes must stay in one AZ."
  type        = number
  default     = 0
}

variable "kube_prometheus_stack_version" {
  description = "kube-prometheus-stack Helm chart version."
  type        = string
  default     = "66.7.1"
}
