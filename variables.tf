variable "region" {
  type        = string
  description = "AWS region where the cluster will be created."
}

variable "aws_account_id" {
  type        = string
  description = "AWS account ID where the cluster will be created."
}

variable "aws_cli_profile" {
  type        = string
  description = "AWS CLI profile to use for the cluster creation."
}

variable "vpc_name" {
  type        = string
  description = "Name of the VPC where the cluster network resources will be provisioned."

}

variable "vpc_id" {
  type        = string
  description = "Id of the VPC where the cluster network resources will be provisioned."
}

variable "subnet_ids" {
  type        = list(string)
  description = "List of subnet IDs where the cluster network resources will be provisioned."
}

variable "cluster_name" {
  type        = string
  description = "Name of the EKS cluster."
}
