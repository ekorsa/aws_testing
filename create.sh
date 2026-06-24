#!/bin/bash
# Provisions: VPC, 2 subnets (2 AZs), IGW, ALB SG, EC2 SG, ALB, Target Group,
# Listener, 2 x EC2 spot t4g.micro.
set -euo pipefail

[ -f "$(dirname "$0")/.env" ] && source "$(dirname "$0")/.env"

REGION="${AWS_REGION:-us-east-1}"
INSTANCE_TYPE="t4g.micro"
KEY_NAME="troubleshoot-key"
STATE_FILE=".state"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── pre-checks ────────────────────────────────────────────────────────────────
if [ -f "$STATE_FILE" ]; then
    echo "ERROR: .state exists. Run ./delete.sh first." >&2; exit 1
fi
[ -f "$SCRIPT_DIR/userdata.sh" ] || { echo "ERROR: userdata.sh not found" >&2; exit 1; }
command -v aws >/dev/null 2>&1 || { echo "ERROR: aws CLI not found" >&2; exit 1; }
aws sts get-caller-identity --region "$REGION" --output text >/dev/null 2>&1 || {
    echo "ERROR: AWS credentials not configured" >&2; exit 1
}

echo "Region:        $REGION"
echo "Instance type: $INSTANCE_TYPE (spot x2)"
echo ""

# ── key pair ──────────────────────────────────────────────────────────────────
if aws ec2 describe-key-pairs --region "$REGION" --key-names "$KEY_NAME" \
        --query 'KeyPairs[0].KeyName' --output text 2>/dev/null | grep -q "$KEY_NAME"; then
    echo "[skip] Key pair '$KEY_NAME' already exists"
else
    echo "[+] Creating key pair..."
    aws ec2 create-key-pair \
        --region "$REGION" --key-name "$KEY_NAME" \
        --query 'KeyMaterial' --output text > "${KEY_NAME}.pem"
    chmod 400 "${KEY_NAME}.pem"
    echo "    Saved to ${KEY_NAME}.pem"
fi

# ── ami (arm64 for t4g) ───────────────────────────────────────────────────────
echo "[+] Looking up latest Amazon Linux 2023 arm64 AMI..."
AMI_ID=$(aws ec2 describe-images \
    --region "$REGION" --owners amazon \
    --filters "Name=name,Values=al2023-ami-2023*-arm64" "Name=state,Values=available" \
    --query 'sort_by(Images, &CreationDate)[-1].ImageId' --output text)
echo "    $AMI_ID"

# ── availability zones ────────────────────────────────────────────────────────
AZ_A="${REGION}a"
AZ_B="${REGION}b"

# ── vpc ───────────────────────────────────────────────────────────────────────
echo "[+] Creating VPC..."
VPC_ID=$(aws ec2 create-vpc \
    --region "$REGION" --cidr-block "10.0.0.0/16" \
    --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=troubleshoot-vpc}]" \
    --query 'Vpc.VpcId' --output text)
aws ec2 modify-vpc-attribute --region "$REGION" --vpc-id "$VPC_ID" --enable-dns-hostnames
aws ec2 modify-vpc-attribute --region "$REGION" --vpc-id "$VPC_ID" --enable-dns-support
echo "    $VPC_ID"

# ── subnets ───────────────────────────────────────────────────────────────────
echo "[+] Creating subnet-a ($AZ_A)..."
SUBNET_A_ID=$(aws ec2 create-subnet \
    --region "$REGION" --vpc-id "$VPC_ID" \
    --cidr-block "10.0.1.0/24" --availability-zone "$AZ_A" \
    --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=troubleshoot-subnet-a}]" \
    --query 'Subnet.SubnetId' --output text)
aws ec2 modify-subnet-attribute --region "$REGION" \
    --subnet-id "$SUBNET_A_ID" --map-public-ip-on-launch
echo "    $SUBNET_A_ID"

echo "[+] Creating subnet-b ($AZ_B)..."
SUBNET_B_ID=$(aws ec2 create-subnet \
    --region "$REGION" --vpc-id "$VPC_ID" \
    --cidr-block "10.0.2.0/24" --availability-zone "$AZ_B" \
    --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=troubleshoot-subnet-b}]" \
    --query 'Subnet.SubnetId' --output text)
aws ec2 modify-subnet-attribute --region "$REGION" \
    --subnet-id "$SUBNET_B_ID" --map-public-ip-on-launch
echo "    $SUBNET_B_ID"

# ── internet gateway ──────────────────────────────────────────────────────────
echo "[+] Creating internet gateway..."
IGW_ID=$(aws ec2 create-internet-gateway \
    --region "$REGION" \
    --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=troubleshoot-igw}]" \
    --query 'InternetGateway.InternetGatewayId' --output text)
aws ec2 attach-internet-gateway \
    --region "$REGION" --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"
echo "    $IGW_ID"

# ── route table (shared for both subnets) ─────────────────────────────────────
echo "[+] Creating route table..."
RTB_ID=$(aws ec2 create-route-table \
    --region "$REGION" --vpc-id "$VPC_ID" \
    --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=troubleshoot-rtb}]" \
    --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-route --region "$REGION" \
    --route-table-id "$RTB_ID" \
    --destination-cidr-block "0.0.0.0/0" \
    --gateway-id "$IGW_ID" >/dev/null
RTB_ASSOC_A_ID=$(aws ec2 associate-route-table \
    --region "$REGION" --route-table-id "$RTB_ID" --subnet-id "$SUBNET_A_ID" \
    --query 'AssociationId' --output text)
RTB_ASSOC_B_ID=$(aws ec2 associate-route-table \
    --region "$REGION" --route-table-id "$RTB_ID" --subnet-id "$SUBNET_B_ID" \
    --query 'AssociationId' --output text)
echo "    $RTB_ID"

# ── security group: ALB ───────────────────────────────────────────────────────
echo "[+] Creating ALB security group..."
ALB_SG_ID=$(aws ec2 create-security-group \
    --region "$REGION" \
    --group-name "troubleshoot-alb-sg" \
    --description "ALB: HTTP from internet" \
    --vpc-id "$VPC_ID" \
    --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=troubleshoot-alb-sg}]" \
    --query 'GroupId' --output text)
aws ec2 authorize-security-group-ingress \
    --region "$REGION" --group-id "$ALB_SG_ID" \
    --protocol tcp --port 80 --cidr "0.0.0.0/0" >/dev/null
echo "    $ALB_SG_ID  (port 80 from 0.0.0.0/0)"

# ── security group: EC2 ───────────────────────────────────────────────────────
echo "[+] Creating EC2 security group..."
EC2_SG_ID=$(aws ec2 create-security-group \
    --region "$REGION" \
    --group-name "troubleshoot-ec2-sg" \
    --description "EC2: HTTP from ALB SG, SSH from internet" \
    --vpc-id "$VPC_ID" \
    --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=troubleshoot-ec2-sg}]" \
    --query 'GroupId' --output text)
# HTTP only from ALB security group — not from internet directly
aws ec2 authorize-security-group-ingress \
    --region "$REGION" --group-id "$EC2_SG_ID" \
    --protocol tcp --port 80 \
    --source-group "$ALB_SG_ID" >/dev/null
aws ec2 authorize-security-group-ingress \
    --region "$REGION" --group-id "$EC2_SG_ID" \
    --protocol tcp --port 22 --cidr "0.0.0.0/0" >/dev/null
echo "    $EC2_SG_ID  (port 80 from ALB SG, port 22 from 0.0.0.0/0)"

# ── launch instances ──────────────────────────────────────────────────────────
launch_instance() {
    local name="$1" subnet="$2"
    aws ec2 run-instances \
        --region "$REGION" \
        --image-id "$AMI_ID" \
        --instance-type "$INSTANCE_TYPE" \
        --key-name "$KEY_NAME" \
        --security-group-ids "$EC2_SG_ID" \
        --subnet-id "$subnet" \
        --user-data "file://$SCRIPT_DIR/userdata.sh" \
        --instance-market-options '{"MarketType":"spot","SpotOptions":{"SpotInstanceType":"persistent","InstanceInterruptionBehavior":"stop"}}' \
        --block-device-mappings '[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":8,"VolumeType":"gp3","DeleteOnTermination":false}}]' \
        --tag-specifications \
            "ResourceType=instance,Tags=[{Key=Name,Value=$name}]" \
            "ResourceType=volume,Tags=[{Key=Name,Value=${name}-vol}]" \
        --query 'Instances[0].InstanceId' --output text
}

echo "[+] Launching instance-1 (subnet-a / $AZ_A)..."
INSTANCE_1_ID=$(launch_instance "troubleshoot-1" "$SUBNET_A_ID")
echo "    $INSTANCE_1_ID"

echo "[+] Launching instance-2 (subnet-b / $AZ_B)..."
INSTANCE_2_ID=$(launch_instance "troubleshoot-2" "$SUBNET_B_ID")
echo "    $INSTANCE_2_ID"

echo "[~] Waiting for both instances to be running..."
aws ec2 wait instance-running \
    --region "$REGION" --instance-ids "$INSTANCE_1_ID" "$INSTANCE_2_ID"

VOLUME_1_ID=$(aws ec2 describe-instances --region "$REGION" \
    --instance-ids "$INSTANCE_1_ID" \
    --query 'Reservations[0].Instances[0].BlockDeviceMappings[0].Ebs.VolumeId' \
    --output text)
VOLUME_2_ID=$(aws ec2 describe-instances --region "$REGION" \
    --instance-ids "$INSTANCE_2_ID" \
    --query 'Reservations[0].Instances[0].BlockDeviceMappings[0].Ebs.VolumeId' \
    --output text)
echo "    vol-1: $VOLUME_1_ID  vol-2: $VOLUME_2_ID"

# ── ALB ───────────────────────────────────────────────────────────────────────
echo "[+] Creating Application Load Balancer..."
ALB_ARN=$(aws elbv2 create-load-balancer \
    --region "$REGION" \
    --name "troubleshoot-alb" \
    --subnets "$SUBNET_A_ID" "$SUBNET_B_ID" \
    --security-groups "$ALB_SG_ID" \
    --scheme internet-facing \
    --type application \
    --query 'LoadBalancers[0].LoadBalancerArn' --output text)
echo "    $ALB_ARN"

echo "[+] Creating target group..."
TG_ARN=$(aws elbv2 create-target-group \
    --region "$REGION" \
    --name "troubleshoot-tg" \
    --protocol HTTP --port 80 \
    --vpc-id "$VPC_ID" \
    --health-check-protocol HTTP \
    --health-check-path "/health" \
    --health-check-interval-seconds 15 \
    --health-check-timeout-seconds 5 \
    --healthy-threshold-count 2 \
    --unhealthy-threshold-count 3 \
    --query 'TargetGroups[0].TargetGroupArn' --output text)
echo "    $TG_ARN"

echo "[+] Registering instances to target group..."
aws elbv2 register-targets \
    --region "$REGION" --target-group-arn "$TG_ARN" \
    --targets "Id=$INSTANCE_1_ID" "Id=$INSTANCE_2_ID" >/dev/null

echo "[+] Creating listener..."
LISTENER_ARN=$(aws elbv2 create-listener \
    --region "$REGION" \
    --load-balancer-arn "$ALB_ARN" \
    --protocol HTTP --port 80 \
    --default-actions "Type=forward,TargetGroupArn=$TG_ARN" \
    --query 'Listeners[0].ListenerArn' --output text)
echo "    $LISTENER_ARN"

# ── save state ────────────────────────────────────────────────────────────────
cat > "$STATE_FILE" << EOF
REGION=$REGION
VPC_ID=$VPC_ID
SUBNET_A_ID=$SUBNET_A_ID
SUBNET_B_ID=$SUBNET_B_ID
IGW_ID=$IGW_ID
RTB_ID=$RTB_ID
RTB_ASSOC_A_ID=$RTB_ASSOC_A_ID
RTB_ASSOC_B_ID=$RTB_ASSOC_B_ID
ALB_SG_ID=$ALB_SG_ID
EC2_SG_ID=$EC2_SG_ID
ALB_ARN=$ALB_ARN
TG_ARN=$TG_ARN
LISTENER_ARN=$LISTENER_ARN
INSTANCE_1_ID=$INSTANCE_1_ID
INSTANCE_2_ID=$INSTANCE_2_ID
VOLUME_1_ID=$VOLUME_1_ID
VOLUME_2_ID=$VOLUME_2_ID
KEY_NAME=$KEY_NAME
AMI_ID=$AMI_ID
EOF

echo ""
echo "[~] Waiting for ALB to become active..."
aws elbv2 wait load-balancer-available \
    --region "$REGION" --load-balancer-arns "$ALB_ARN"

ALB_DNS=$(aws elbv2 describe-load-balancers \
    --region "$REGION" --load-balancer-arns "$ALB_ARN" \
    --query 'LoadBalancers[0].DNSName' --output text)

IP_1=$(aws ec2 describe-instances --region "$REGION" \
    --instance-ids "$INSTANCE_1_ID" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
IP_2=$(aws ec2 describe-instances --region "$REGION" \
    --instance-ids "$INSTANCE_2_ID" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)

echo ""
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  Environment ready                                               ║"
echo "╠══════════════════════════════════════════════════════════════════╣"
printf "║  App (via ALB): http://%-41s║\n" "$ALB_DNS"
echo "╠══════════════════════════════════════════════════════════════════╣"
printf "║  Instance-1: %-51s║\n" "$INSTANCE_1_ID  ($AZ_A)"
printf "║  SSH-1: ssh -i ${KEY_NAME}.pem -o IdentitiesOnly=yes ec2-user@%s\n" "$IP_1"
printf "║  Instance-2: %-51s║\n" "$INSTANCE_2_ID  ($AZ_B)"
printf "║  SSH-2: ssh -i ${KEY_NAME}.pem -o IdentitiesOnly=yes ec2-user@%s\n" "$IP_2"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""
echo "NOTE: app bootstraps ~90 sec. Check ./status.sh"
