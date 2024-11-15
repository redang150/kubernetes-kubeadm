#!/bin/bash

# Set environment variables (replace with your actual values)
export AWS_REGION="us-east-2"           # e.g., us-east-1
export S3_BUCKET="dominionclass37"      # e.g., my-kops-state-store
export CLUSTER_NAME="dominionclass37.k8s.local" # e.g., my-cluster.k8s.local

# Confirm deletion
echo "WARNING: This script will delete the Kubernetes cluster '${CLUSTER_NAME}' and the S3 state store bucket '${S3_BUCKET}'."
read -p "Are you sure you want to proceed? (yes/no): " confirm
if [ "$confirm" != "yes" ]; then
    echo "Aborting script."
    exit 1
fi

# Export the KOPS_STATE_STORE environment variable
export KOPS_STATE_STORE="s3://${S3_BUCKET}"

# 1. Delete the Kubernetes cluster managed by kops
echo "Deleting Kubernetes cluster '${CLUSTER_NAME}'..."
kops delete cluster --name ${CLUSTER_NAME} --state ${KOPS_STATE_STORE} --yes

# 2. Verify deletion of the cluster
echo "Verifying cluster deletion..."
kops validate cluster --name ${CLUSTER_NAME} --state ${KOPS_STATE_STORE}
if [ $? -eq 0 ]; then
    echo "Cluster '${CLUSTER_NAME}' deletion may not have completed successfully."
    exit 1
else
    echo "Cluster '${CLUSTER_NAME}' successfully deleted."
fi

# 3. Delete the S3 bucket used for the kops state store
echo "Deleting S3 bucket '${S3_BUCKET}'..."
aws s3 rm s3://${S3_BUCKET} --recursive
aws s3api delete-bucket --bucket ${S3_BUCKET} --region ${AWS_REGION}

# Confirm S3 bucket deletion
if aws s3api head-bucket --bucket "${S3_BUCKET}" 2>/dev/null; then
    echo "Error: S3 bucket '${S3_BUCKET}' could not be deleted."
    exit 1
else
    echo "S3 bucket '${S3_BUCKET}' successfully deleted."
fi

echo "All resources associated with the kops cluster '${CLUSTER_NAME}' have been destroyed."
