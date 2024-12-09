############################################
# VPC
############################################
module "vpc" {
  source = "terraform-aws-modules/vpc/aws"

  name = var.vpc_name
  cidr = "10.0.0.0/16"

  azs = ["${var.region}a", "${var.region}b", "${var.region}c"]
  # This subnets will have a direct route to an internet gateway. Resources in a public subnet can access the public internet.
  public_subnets = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]
  # This subnets will use a NAT gateway to access the public internet. 
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  # This subnets will have no internet routing
  intra_subnets = ["10.0.104.0/24", "10.0.105.0/24", "10.0.106.0/24"]

  # Should be true if you want to provision NAT Gateway(s) for your private networks
  enable_nat_gateway = true
  # ALL private subnets will route their Internet traffic through this single NAT gateway
  single_nat_gateway = true
  # Should be false if you do not want one NAT Gateway per availability zone.
  one_nat_gateway_per_az = false

  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
    # Tags subnets for Karpenter auto-discovery (This will allow Karpenter to discover the subnets where to create nodes)
    "karpenter.sh/discovery" = var.cluster_name
  }

  tags = {
    Terraform   = "true"
    Environment = "dev"
  }
}


############################################
# EKS
############################################
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "20.31.0"

  cluster_name    = var.cluster_name
  cluster_version = "1.31"

  cluster_endpoint_public_access = true

  cluster_addons = {
    coredns                = {}
    eks-pod-identity-agent = {}
    kube-proxy             = {}
    vpc-cni                = {}
  }

  vpc_id                   = module.vpc.vpc_id
  subnet_ids               = module.vpc.private_subnets
  control_plane_subnet_ids = module.vpc.intra_subnets

  # Every managed node is provisioned as part of an Amazon EC2 Auto Scaling group that’s managed for you by Amazon EKS.
  # These nodes are automatically tagged for auto-discovery by the Kubernetes Cluster Autoscaler.
  eks_managed_node_groups = {
    karpenter = {
      # Starting on 1.30, AL2023 is the default AMI type for EKS managed node groups. It contains kubelet & containerd
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = ["t3.medium"]

      min_size     = 1
      max_size     = 3
      desired_size = 1

      taints = {
        # This taint aims to keep just EKS Add-ons and Karpenter running on the node group
        # The pods that do not have the toleration to this taint will not be scheduled on the node group
        addons = {
          key    = "CriticalAddonsOnly"
          value  = "true"
          effect = "NO_SCHEDULE"
        }
      }
    }
  }

  # Cluster access entry
  # Adds the current caller identity as an administrator via cluster access entry
  enable_cluster_creator_admin_permissions = true

  node_security_group_tags = {
    # Tags the security group of the managed node
    "karpenter.sh/discovery" = var.cluster_name
  }

  tags = {
    Environment = "dev"
    Terraform   = "true"
  }
}

############################################
# Karpenter
############################################
module "karpenter" {
  source = "terraform-aws-modules/eks/aws//modules/karpenter"

  cluster_name = module.eks.cluster_name

  # Determines whether to enable permissions suitable for v1+
  enable_v1_permissions = true

  # This will create an IAM role & a pod identity association to grant karpenter controller acces provided by the IAM role
  # It will also create a Node IAM role that karpenter will use to create an instance profile for the nodes to receive IAM permissions
  # And then an access entry for the Node IAM role to allow nodes to join the cluster
  # Lastly, it will create a sqs & event bridge rules for Karpenter to utilize for SPOT termination, capacity rebalancing, etc.
  enable_pod_identity             = true
  create_pod_identity_association = true

  # Attach additional IAM policies to the Karpenter node IAM role
  node_iam_role_additional_policies = {
    # if you need access to the nodes, use SSM instead of SSH keys. Useful for debugging purposes
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  tags = {
    Environment = "dev"
    Terraform   = "true"
  }
}

############################################
# Karpenter Helm Chart
############################################
resource "helm_release" "karpenter" {
  namespace           = "kube-system"
  name                = "karpenter"
  repository          = "oci://public.ecr.aws/karpenter"
  repository_username = data.aws_ecrpublic_authorization_token.token.user_name
  repository_password = data.aws_ecrpublic_authorization_token.token.password
  chart               = "karpenter"
  version             = "1.1.0"
  wait                = false
  values = [
    <<-EOT
    replicaCount: 1
    serviceAccount:
      name: ${module.karpenter.service_account}
    settings:
      clusterName: ${module.eks.cluster_name}
      clusterEndpoint: ${module.eks.cluster_endpoint}
      interruptionQueue: ${module.karpenter.queue_name}
    EOT
  ]
}

############################################
# Karpenter Node class
############################################
resource "kubectl_manifest" "karpenter_node_class" {
  yaml_body = <<-YAML
    apiVersion: karpenter.k8s.aws/v1
    kind: EC2NodeClass
    metadata:
      name: default
    spec:
      amiFamily: AL2023
      role: ${module.karpenter.node_iam_role_name}
      subnetSelectorTerms:
        - tags:
            karpenter.sh/discovery: ${module.eks.cluster_name}
      securityGroupSelectorTerms:
        - tags:
            karpenter.sh/discovery: ${module.eks.cluster_name}
      amiSelectorTerms:
        - alias: al2023@latest
      tags:
        karpenter.sh/discovery: ${module.eks.cluster_name}
  YAML

  depends_on = [
    helm_release.karpenter
  ]
}

############################################
# Karpenter Node Pool
############################################
resource "kubectl_manifest" "karpenter_node_pool" {
  yaml_body = <<-YAML
    apiVersion: karpenter.sh/v1
    kind: NodePool
    metadata:
      name: default
    spec:
      template:
        spec:
          nodeClassRef:
            group: karpenter.k8s.aws
            kind: EC2NodeClass
            name: default
          requirements:
            - key: "karpenter.k8s.aws/instance-category"
              operator: In
              values: ["m", "t"]
            - key: "karpenter.k8s.aws/instance-cpu"
              operator: In
              values: ["2", "4"]
            - key: "karpenter.k8s.aws/instance-hypervisor"
              operator: In
              values: ["nitro"]
            - key: "karpenter.k8s.aws/instance-generation"
              operator: Gt
              values: ["2", "3"]
            - key: "karpenter.sh/capacity-type"
              operator: In
              values: ["spot"]
            - key: "kubernetes.io/os"
              operator: In
              values: ["linux"]
      limits:
        cpu: 100
      disruption:
        consolidationPolicy: WhenUnderutilized
        consolidateAfter: 30s
  YAML

  depends_on = [
    kubectl_manifest.karpenter_node_class
  ]
}

###############################################################################
# Inflate deployment
###############################################################################
resource "kubectl_manifest" "karpenter_example_deployment" {
  yaml_body = <<-YAML
    apiVersion: apps/v1
    kind: Deployment
    metadata:
      name: inflate
    spec:
      replicas: 0
      selector:
        matchLabels:
          app: inflate
      template:
        metadata:
          labels:
            app: inflate
        spec:
          terminationGracePeriodSeconds: 0
          containers:
            - name: inflate
              image: public.ecr.aws/eks-distro/kubernetes/pause:3.7
              resources:
                requests:
                  cpu: 1
  YAML

  depends_on = [
    helm_release.karpenter
  ]
}
