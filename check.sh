#!/bin/bash
# Checks whether any troubleshoot-* resources still exist in AWS.
# Useful after ./delete.sh to confirm everything is gone.
set -euo pipefail

[ -f "$(dirname "$0")/.env" ] && source "$(dirname "$0")/.env"

REGION="${AWS_REGION:-us-east-1}"
FOUND=0

check() {
    local label="$1"
    local result="$2"
    local count
    count=$(echo "$result" | grep -c . 2>/dev/null || true)
    if [ "$count" -gt 0 ]; then
        echo "[ EXISTS ] $label"
        echo "$result" | sed 's/^/           /'
        FOUND=$((FOUND + 1))
    else
        echo "[   ok   ] $label — не найдено"
    fi
}

echo "=== Проверка остатков troubleshoot-* ресурсов (region: $REGION) ==="
echo ""

# EC2 instances (excluding terminated)
check "EC2 instances" "$(aws ec2 describe-instances \
    --region "$REGION" \
    --filters "Name=tag:Name,Values=troubleshoot-*" \
    --query 'Reservations[*].Instances[?State.Name!=`terminated`].[Tags[?Key==`Name`].Value|[0],InstanceId,State.Name]' \
    --output text 2>/dev/null)"

# VPC
check "VPC" "$(aws ec2 describe-vpcs \
    --region "$REGION" \
    --filters "Name=tag:Name,Values=troubleshoot-*" \
    --query 'Vpcs[*].[Tags[?Key==`Name`].Value|[0],VpcId,State]' \
    --output text 2>/dev/null)"

# Subnets
check "Subnets" "$(aws ec2 describe-subnets \
    --region "$REGION" \
    --filters "Name=tag:Name,Values=troubleshoot-*" \
    --query 'Subnets[*].[Tags[?Key==`Name`].Value|[0],SubnetId,State]' \
    --output text 2>/dev/null)"

# Internet Gateway
check "Internet Gateway" "$(aws ec2 describe-internet-gateways \
    --region "$REGION" \
    --filters "Name=tag:Name,Values=troubleshoot-*" \
    --query 'InternetGateways[*].[Tags[?Key==`Name`].Value|[0],InternetGatewayId,Attachments[0].State]' \
    --output text 2>/dev/null)"

# Security Groups
check "Security Groups" "$(aws ec2 describe-security-groups \
    --region "$REGION" \
    --filters "Name=tag:Name,Values=troubleshoot-*" \
    --query 'SecurityGroups[*].[Tags[?Key==`Name`].Value|[0],GroupId,GroupName]' \
    --output text 2>/dev/null)"

# ALB
check "ALB" "$(aws elbv2 describe-load-balancers \
    --region "$REGION" \
    --query 'LoadBalancers[?contains(LoadBalancerName,`troubleshoot`)].[LoadBalancerName,State.Code]' \
    --output text 2>/dev/null)"

# Target Groups
check "Target Groups" "$(aws elbv2 describe-target-groups \
    --region "$REGION" \
    --query 'TargetGroups[?contains(TargetGroupName,`troubleshoot`)].[TargetGroupName,TargetGroupArn]' \
    --output text 2>/dev/null)"

# EBS Volumes
check "EBS Volumes" "$(aws ec2 describe-volumes \
    --region "$REGION" \
    --filters "Name=tag:Name,Values=troubleshoot-*" \
    --query 'Volumes[*].[Tags[?Key==`Name`].Value|[0],VolumeId,State]' \
    --output text 2>/dev/null)"

# Key Pair
check "Key Pair" "$(aws ec2 describe-key-pairs \
    --region "$REGION" \
    --filters "Name=key-name,Values=troubleshoot-*" \
    --query 'KeyPairs[*].[KeyName,KeyPairId]' \
    --output text 2>/dev/null)"

# Spot requests (active/open only)
check "Spot Requests" "$(aws ec2 describe-spot-instance-requests \
    --region "$REGION" \
    --filters "Name=state,Values=open,active" \
                "Name=tag:Name,Values=troubleshoot-*" \
    --query 'SpotInstanceRequests[*].[SpotInstanceRequestId,State,Status.Code]' \
    --output text 2>/dev/null)"

echo ""
if [ "$FOUND" -eq 0 ]; then
    echo "Всё чисто — ресурсов не найдено."
else
    echo "Найдено групп ресурсов: $FOUND. Запусти ./delete.sh для очистки."
fi
