# EKS-KARPENTER

Configuration in this directory creates an AWS EKS cluster with Karpenter provisioned for managing compute resource scaling. In the example provided, Karpenter is provisioned on top of an EKS Managed Node Group.


## Setting Up Terraform with S3 Backend and DynamoDB Locking

### Prerequisites

Before you begin, ensure you have the following :
- An AWS account with the necessary permissions to create S3 buckets and DynamoDB tables. 
- Terraform installed on your local machine.
- AWS CLI configured with your credentials :
  
  ```shell
  # If you do not use the profile-name, a default profile will be created
  aws configure --profile <your-profile-name>
  # View the current configuration
  aws configure list --profile <your-profile-name>
  ```
- Unless your AWS account has already onboarded to EC2 Spot, you will need to create the service linked role :
  ```shell
  aws iam create-service-linked-role --aws-service-name spot.amazonaws.com --profile <your-profile-name>
  ```
  
### Step1 ~> Create an S3 Bucket
First, you’ll need an S3 bucket to store your Terraform state files. Open your terminal and run the following AWS CLI command to create a new S3 bucket:

  ```shell
  aws s3api create-bucket --bucket <your-terraform-state-bucket> --create-bucket-configuration LocationConstraint=<your-region> --profile <your-profile-name>
  ```

### Step2 ~> Optional : Enable Versioning on the S3 Bucket
Enabling versioning on your S3 bucket ensures that you have a history of your Terraform state files, which can be useful for recovery and debugging. Run the following command to enable versioning:

  ```shell
  aws s3api put-bucket-versioning --bucket <your-terraform-state-bucket> --versioning-configuration Status=Enabled --profile <your-profile-name>
  ```

### Step3 ~> Optional : Enable SSE encryption
For added security, you should enable server-side encryption for your S3 bucket:

  ```shell
  aws s3api put-bucket-encryption --bucket <your-terraform-state-bucket> --server-side-encryption-configuration '{
    "Rules": [
      {
        "ApplyServerSideEncryptionByDefault": {
          "SSEAlgorithm": "AES256"
        }
      }
    ]
  }' --profile <your-profile-name>
  ```

### Step4 ~> Create a DynamoDB Table for State Locking
Next, create a DynamoDB table to handle state locking. This prevents concurrent Terraform executions, which can lead to state corruption. Run the following command:
  ```shell
  aws dynamodb create-table \
    --table-name <your-terraform-lock-table> \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --provisioned-throughput ReadCapacityUnits=5,WriteCapacityUnits=5 --profile <your-profile-name>
  ```

You can adjust the ReadCapacityUnits and WriteCapacityUnits as needed based on your expected usage.

### Step5 ~> Configure the Terraform Backend
With your S3 bucket and DynamoDB table ready, you can configure Terraform to use them as the backend. Create or update your backend.tf file with the following configuration:

  ```
  provider "aws" {
    region              = <your-region>
    allowed_account_ids = [<your-aws-account-id>]
    profile             = <your-profile-name>
  }

  terraform {
    required_providers {
      aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
      }
    }

    backend "s3" {
      bucket         = "<your-terraform-state-bucket>"
      key            = "terraform/state"
      region         = "<your-region>"
      dynamodb_table = "<your-terraform-lock-table>"
      profile        = "<your-profile-name>"
    }
  }
  ```

### Step6 ~> Initialize the Terraform Backend
Now, initialize your Terraform configuration to use the new backend:

  ```shell
  terraform init
  ```

### Step7 ~> Verify the Configuration
Finally, verify that your Terraform setup is working correctly by applying your configuration:

  ```shell
  terraform apply
  ```

## Setting Up VPC, EKS & Karpenter

The file `main.tf` uses the official Terraform modules to create the vpc and the EKS cluster.

```shell
  terraform init
  terraform plan
  terraform apply --auto-approve
```

Once the cluster is up and running, you can check that Karpenter is functioning as intended with the following command:

```shell
# First, make sure you have updated your local kubeconfig
aws eks --region eu-west-1 update-kubeconfig --name ex-karpenter

# Second, scale the example deployment
kubectl scale deployment inflate --replicas 5

# You can watch Karpenter's controller logs with
kubectl logs -f -n kube-system -l app.kubernetes.io/name=karpenter -c controller
```

Validate if the Amazon EKS Addons Pods are running in the Managed Node Group and the inflate application Pods are running on Karpenter provisioned Nodes.

```shell
kubectl get nodes -L karpenter.sh/registered
kubectl get pods -A -o custom-columns=NAME:.metadata.name,NODE:.spec.nodeName
```

## Tear Down & Clean-Up

Because Karpenter manages the state of node resources outside of Terraform, Karpenter created resources will need to be de-provisioned first before removing the remaining resources with Terraform.

1. Remove the example deployment created above and any nodes created by Karpenter

```shell
kubectl delete deployment inflate
kubectl delete node -l karpenter.sh/provisioner-name=default
```

2. Remove the resources created by Terraform

```shell
terraform destroy --auto-approve
```

Note that this example may create resources which cost money. Run `terraform destroy` when you don't need these resources.
