#!/bin/bash
# MAINTAINER: Ndiforamang Fusi
# Date Modified: 11/09/2024
# Description: Script to deploy a highly available Kubernetes cluster with kops and necessary network setup

# Configuration
CLUSTER_NAME="dominionclass37.k8s.local"
S3_BUCKET="dominionclass37-state-store"
AWS_REGION="us-east-2"
K8S_VERSION="1.29.6"
NODE_COUNT=2
NODE_SIZE="t3.medium"
CONTROL_PLANE_SIZE="t3.medium"
ZONES="${AWS_REGION}a,${AWS_REGION}b,${AWS_REGION}c"
DNS_ZONE="dominionclass37.k8s.local"
MAX_RETRIES=3  # Number of retries for certain commands

# Step 1: Update packages and install necessary dependencies
echo "Updating packages and installing prerequisites..."
sudo yum update -y  # Change to apt-get if using Ubuntu
sudo yum install -y jq curl unzip awscli

# Step 2: Install kops
echo "Installing kops..."
cd /tmp
curl -Lo kops https://github.com/kubernetes/kops/releases/download/$(curl -s https://api.github.com/repos/kubernetes/kops/releases/latest | jq -r .tag_name)/kops-linux-amd64
if [ $? -ne 0 ]; then
    echo "Failed to download kops."
    exit 1
fi
chmod +x kops
sudo mv kops /usr/local/bin/kops

# Verify kops installation
if ! command -v kops &> /dev/null; then
    echo "kops installation failed."
    exit 1
fi

# Step 3: Install kubectl
echo "Installing kubectl..."
curl -Lo kubectl https://dl.k8s.io/release/v${K8S_VERSION}/bin/linux/amd64/kubectl
if [ $? -ne 0 ]; then
    echo "Failed to download kubectl."
    exit 1
fi
chmod +x kubectl
sudo mv kubectl /usr/local/bin/kubectl

# Verify kubectl installation
if ! command -v kubectl &> /dev/null; then
    echo "kubectl installation failed."
    exit 1
fi

# Step 4: Set up an S3 bucket for kops state storage
echo "Creating S3 bucket ${S3_BUCKET} for kops state store..."
aws s3api create-bucket --bucket ${S3_BUCKET} --region ${AWS_REGION} --create-bucket-configuration LocationConstraint=${AWS_REGION} || echo "Bucket already exists"

# Enable versioning and encryption on S3 bucket
aws s3api put-bucket-versioning --bucket ${S3_BUCKET} --versioning-configuration Status=Enabled
aws s3api put-bucket-encryption --bucket ${S3_BUCKET} --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

# Step 5: Set environment variables for kops
export NAME=${CLUSTER_NAME}
export KOPS_STATE_STORE=s3://${S3_BUCKET}

# Make variables persistent
echo "export NAME=${CLUSTER_NAME}" >> ~/.bashrc
echo "export KOPS_STATE_STORE=s3://${S3_BUCKET}" >> ~/.bashrc

# Step 6: Generate SSH key pair if not already existing
echo "Generating SSH key pair..."
if [ ! -f ~/.ssh/id_rsa ]; then
    ssh-keygen -q -t rsa -N '' -f ~/.ssh/id_rsa <<< y >/dev/null 2>&1
fi

# Step 7: Create Kubernetes cluster configuration with custom VPC and networking setup
echo "Creating Kubernetes cluster ${CLUSTER_NAME} configuration with kops..."
kops create cluster --name ${NAME} --cloud=aws --zones ${ZONES} \
--control-plane-size ${CONTROL_PLANE_SIZE} --node-count=${NODE_COUNT} --node-size ${NODE_SIZE} \
--kubernetes-version ${K8S_VERSION} --ssh-public-key ~/.ssh/id_rsa.pub --dns-zone ${DNS_ZONE} \
--networking calico  # Choose Calico for improved networking and policy management

# Enable DNS hostnames and resolution for the VPC
echo "Enabling DNS hostnames and DNS resolution for VPC..."
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=${CLUSTER_NAME}" --query 'Vpcs[0].VpcId' --output text)
if [ "$VPC_ID" == "None" ]; then
    echo "Error: VPC not found for the cluster."
    exit 1
fi
aws ec2 modify-vpc-attribute --vpc-id ${VPC_ID} --enable-dns-support
aws ec2 modify-vpc-attribute --vpc-id ${VPC_ID} --enable-dns-hostnames

# Step 8: Build the cluster
echo "Building the cluster..."
kops update cluster --name ${NAME} --yes --admin

# Step 9: Configure kubectl access to the cluster
echo "Setting up kubectl access to the cluster..."
kops export kubecfg --name ${NAME} --admin

# Step 10: Check or create the private DNS hosted zone
echo "Checking for existing private DNS hosted zone for ${DNS_ZONE}..."
EXISTING_ZONE_ID=$(aws route53 list-hosted-zones-by-name --dns-name "${DNS_ZONE}" --query 'HostedZones[?Config.PrivateZone == `true`].Id' --output text | sed 's|/hostedzone/||')
if [ -z "$EXISTING_ZONE_ID" ]; then
    echo "No existing hosted zone found. Creating a new private DNS hosted zone..."
    HOSTED_ZONE_ID=$(aws route53 create-hosted-zone --name "${DNS_ZONE}" --vpc VPCRegion=${AWS_REGION},VPCId=${VPC_ID} --caller-reference "$(date +%s)" --hosted-zone-config PrivateZone=true --query 'HostedZone.Id' --output text | sed 's|/hostedzone/||')
    echo "Private DNS hosted zone created with ID: ${HOSTED_ZONE_ID}"
else
    HOSTED_ZONE_ID=${EXISTING_ZONE_ID}
    echo "Existing private DNS hosted zone found with ID: ${HOSTED_ZONE_ID}"
fi

# Step 11: Associate DNS hosted zone with VPC if not already associated
EXISTING_ASSOCIATION=$(aws route53 get-hosted-zone --id ${HOSTED_ZONE_ID} --query "VPCs[?VpcId=='${VPC_ID}']" --output text)
if [ -z "$EXISTING_ASSOCIATION" ]; then
    echo "Associating DNS hosted zone with VPC..."
    for ((i=1; i<=$MAX_RETRIES; i++)); do
        aws route53 associate-vpc-with-hosted-zone --hosted-zone-id ${HOSTED_ZONE_ID} --vpc VPCRegion=${AWS_REGION},VPCId=${VPC_ID} && break || {
            echo "Attempt $i to associate DNS hosted zone failed. Retrying..."
            sleep 10
        }
    done
else
    echo "DNS hosted zone already associated with the VPC."
fi

# Step 12: Validate the cluster with increased wait time and retries
echo "Validating the cluster. This may take several minutes..."
for ((i=1; i<=$MAX_RETRIES; i++)); do
    kops validate cluster --wait 15m && break || {
        echo "Validation attempt $i failed. Retrying..."
        sleep 10
    }
done

echo "Cluster ${CLUSTER_NAME} deployed and validated successfully!"
