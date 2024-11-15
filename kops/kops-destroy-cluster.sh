#!/bin/bash
# MAINTAINER: Ndiforamang Fusi
# Date Modified: 11/09/2024
# Description: Script to destroy all resources created by the Kubernetes deployment script

# Set environment variables for kops (same as in the setup script)
export NAME="dominionclass37.k8s.local"
export KOPS_STATE_STORE="s3://dominionclass37-state-store"
AWS_REGION="us-east-2"
S3_BUCKET="dominionclass37-state-store"
COMMAND_TIMEOUT=300  # Timeout for AWS CLI commands
MAX_RETRIES=3  # Number of retries for deletion commands
RETRY_DELAY=10  # Delay between retries in seconds

# Step 1: Delete the Kubernetes cluster
echo "Checking if Kubernetes cluster exists..."
if kops get cluster --name ${NAME} --state ${KOPS_STATE_STORE} --region ${AWS_REGION} > /dev/null 2>&1; then
  echo "Cluster ${NAME} found. Proceeding with deletion..."

  # Delete the Kubernetes cluster
  kops delete cluster --name ${NAME} --yes --state ${KOPS_STATE_STORE} --region ${AWS_REGION}
else
  echo "Cluster ${NAME} does not exist. Skipping cluster deletion."
fi

# Step 2: Delete any Auto Scaling Groups associated with the cluster
echo "Deleting associated Auto Scaling Groups..."
ASG_IDS=$(aws autoscaling describe-auto-scaling-groups \
  --region ${AWS_REGION} \
  --query "AutoScalingGroups[?contains(Tags[?Key=='kubernetes.io/cluster/${NAME}'].Value, 'owned')].AutoScalingGroupName" \
  --output text)

if [ -n "$ASG_IDS" ]; then
  for asg_id in $ASG_IDS; do
    echo "Deleting ASG: $asg_id"
    # Check if the ASG exists before attempting to delete
    if aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$asg_id" --region ${AWS_REGION} > /dev/null 2>&1; then
      aws autoscaling update-auto-scaling-group --auto-scaling-group-name "$asg_id" --min-size 0 --max-size 0 --desired-capacity 0 --region ${AWS_REGION}
      aws autoscaling delete-auto-scaling-group --auto-scaling-group-name "$asg_id" --region ${AWS_REGION} --force-delete
    else
      echo "Warning: Auto Scaling Group $asg_id not found. Skipping."
    fi
  done
else
  echo "No ASGs found for the cluster ${NAME}."
fi

# Step 3: Delete Load Balancers
echo "Deleting target groups and associated network load balancers..."
# Find all load balancers associated with the cluster
LB_ARNS=$(aws elbv2 describe-load-balancers \
  --query "LoadBalancers[?contains(LoadBalancerName, '${NAME}')].LoadBalancerArn" \
  --output text \
  --region ${AWS_REGION})

if [ -n "$LB_ARNS" ]; then
  for lb_arn in $LB_ARNS; do
    echo "Processing Load Balancer: $lb_arn"

    # Find target groups associated with each load balancer
    TARGET_GROUP_ARNS=$(aws elbv2 describe-target-groups \
      --query "TargetGroups[?LoadBalancerArns[0]=='${lb_arn}'].TargetGroupArn" \
      --output text \
      --region ${AWS_REGION})

    # Delete target groups associated with the load balancer
    if [ -n "$TARGET_GROUP_ARNS" ]; then
      for tg_arn in $TARGET_GROUP_ARNS; do
        echo "Deleting Target Group: $tg_arn"
        retry_command timeout $COMMAND_TIMEOUT aws elbv2 delete-target-group --target-group-arn $tg_arn --region ${AWS_REGION}
      done
    else
      echo "No target groups found for load balancer $lb_arn."
    fi

    # Delete the load balancer after deleting target groups
    echo "Deleting Load Balancer: $lb_arn"
    retry_command timeout $COMMAND_TIMEOUT aws elbv2 delete-load-balancer --load-balancer-arn $lb_arn --region ${AWS_REGION}
  done
else
  echo "No load balancers found for the cluster ${NAME}."
fi


# Step 4: Terminate EC2 instances associated with the cluster
echo "Terminating EC2 instances..."
INSTANCE_IDS=$(aws ec2 describe-instances \
  --filters "Name=tag:kubernetes.io/cluster/${NAME},Values=owned" \
  --query "Reservations[].Instances[].InstanceId" \
  --output text \
  --region ${AWS_REGION})
if [ -n "$INSTANCE_IDS" ]; then
  aws ec2 terminate-instances --instance-ids $INSTANCE_IDS --region ${AWS_REGION}
  echo "Waiting for instances to terminate..."
  aws ec2 wait instance-terminated --instance-ids $INSTANCE_IDS --region ${AWS_REGION} || echo "Error waiting for instance termination. Instances may already be terminated."
else
  echo "No EC2 instances found for the cluster ${NAME}."
fi

# Step 5: Delete VPC and associated resources
echo "Deleting VPC..."
VPC_ID=$(aws ec2 describe-vpcs \
  --filters "Name=tag:kubernetes.io/cluster/${NAME},Values=owned" \
  --query "Vpcs[].VpcId" \
  --output text \
  --region ${AWS_REGION})
if [ -n "$VPC_ID" ]; then
  # Delete dependent resources within the VPC

  # Delete subnets
  SUBNET_IDS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=${VPC_ID}" --query "Subnets[].SubnetId" --output text --region ${AWS_REGION})
  for subnet_id in $SUBNET_IDS; do
    echo "Deleting Subnet: $subnet_id"
    aws ec2 delete-subnet --subnet-id $subnet_id --region ${AWS_REGION} || echo "Error deleting subnet $subnet_id. It may already be deleted."
  done

  # Delete route tables
  RTB_IDS=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=${VPC_ID}" --query "RouteTables[].RouteTableId" --output text --region ${AWS_REGION})
  for rtb_id in $RTB_IDS; do
    echo "Deleting Route Table: $rtb_id"
    aws ec2 delete-route-table --route-table-id $rtb_id --region ${AWS_REGION} || echo "Error deleting route table $rtb_id. It may already be deleted."
  done

  # Detach and delete internet gateways
  IGW_IDS=$(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=${VPC_ID}" --query "InternetGateways[].InternetGatewayId" --output text --region ${AWS_REGION})
  for igw_id in $IGW_IDS; do
    echo "Detaching and deleting Internet Gateway: $igw_id"
    aws ec2 detach-internet-gateway --internet-gateway-id $igw_id --vpc-id $VPC_ID --region ${AWS_REGION} || echo "Error detaching Internet Gateway $igw_id."
    aws ec2 delete-internet-gateway --internet-gateway-id $igw_id --region ${AWS_REGION} || echo "Error deleting Internet Gateway $igw_id. It may already be deleted."
  done

  # Delete the VPC
  aws ec2 delete-vpc --vpc-id $VPC_ID --region ${AWS_REGION} || echo "Error deleting VPC $VPC_ID. It may already be deleted."
else
  echo "No VPC found for the cluster ${NAME}."
fi

# Step 6: Delete all objects and versions in the S3 bucket
echo "Deleting all objects and versions in the S3 bucket..."
if aws s3api head-bucket --bucket ${S3_BUCKET} 2>/dev/null; then
  aws s3api list-object-versions --bucket ${S3_BUCKET} --output json |
    jq -r '.Versions[]? | .Key + " " + .VersionId' |
    while read -r key version; do
      aws s3api delete-object --bucket ${S3_BUCKET} --key "$key" --version-id "$version"
    done

  aws s3api list-object-versions --bucket ${S3_BUCKET} --output json |
    jq -r '.DeleteMarkers[]? | .Key + " " + .VersionId' |
    while read -r key version; do
      aws s3api delete-object --bucket ${S3_BUCKET} --key "$key" --version-id "$version"
    done

  # Delete the S3 bucket used for state storage
  echo "Deleting S3 bucket..."
  aws s3 rb s3://${S3_BUCKET} --force || echo "Error deleting S3 bucket ${S3_BUCKET}. It may already be deleted."
else
  echo "S3 bucket ${S3_BUCKET} does not exist. Skipping deletion."
fi

echo "All resources have been deleted."
