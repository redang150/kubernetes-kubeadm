#!/bin/bash

# Set environment variables
export AWS_REGION="us-east-2"           # e.g., us-east-1
export S3_BUCKET="dominionclass37-state-store"      # e.g., my-kops-state-store
export CLUSTER_NAME="dominionsystem.org" # e.g., my-cluster.k8s.local
ZONES="${AWS_REGION}a,${AWS_REGION}b,${AWS_REGION}c"

# Install essential packages
sudo yum update -y
sudo yum upgrade -y
sudo yum install -y unzip curl jq awscli

# Install kubectl
echo "Installing kubectl..."
curl -LO "https://dl.k8s.io/release/$(curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl
sudo mv kubectl /usr/local/bin/

# Install kops
echo "Installing kops..."
curl -Lo kops https://github.com/kubernetes/kops/releases/download/$(curl -s https://api.github.com/repos/kubernetes/kops/releases/latest | jq -r .tag_name)/kops-linux-amd64
chmod +x kops
sudo mv kops /usr/local/bin/

# Step 4: Set up an S3 bucket for kops state storage
echo "Creating S3 bucket ${S3_BUCKET} for kops state store..."
aws s3api create-bucket --bucket ${S3_BUCKET} --region ${AWS_REGION} --create-bucket-configuration LocationConstraint=${AWS_REGION} || echo "Bucket already exists"

# Enable versioning and encryption on S3 bucket
aws s3api put-bucket-versioning --bucket ${S3_BUCKET} --versioning-configuration Status=Enabled
aws s3api put-bucket-encryption --bucket ${S3_BUCKET} --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

# Step 5: Set environment variables for kops
export NAME=${CLUSTER_NAME}
export KOPS_STATE_STORE="s3://${S3_BUCKET}"

# Make variables persistent
echo "export NAME=${CLUSTER_NAME}" >> ~/.bashrc
echo "export KOPS_STATE_STORE=s3://${S3_BUCKET}" >> ~/.bashrc

# Generate SSH keys (if not already generated)
echo "Generating SSH key for cluster access..."
if [ ! -f ~/.ssh/id_rsa ]; then
    ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa -N ""
else
    echo "SSH key already exists. Skipping generation."
fi

# Create Kubernetes cluster without specifying DNS zone (using gossip-based DNS)
echo "Creating Kubernetes cluster..."
kops create cluster \
  --name=${NAME} \
  --state=${KOPS_STATE_STORE} \
  --zones ${ZONES} \
  --node-count=2 \
  --node-size=t3.medium \
  --master-size=t3.medium \
  --master-volume-size=8 \

# Update the cluster configuration
kops update cluster --name ${NAME} --state ${KOPS_STATE_STORE} --yes

# Validate the cluster
echo "Validating cluster..."
kops validate cluster --name ${NAME} --state ${KOPS_STATE_STORE}

echo "Cluster setup complete. You can now manage it with kubectl."
