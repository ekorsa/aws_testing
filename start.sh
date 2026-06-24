#!/bin/bash
# Starts stopped instances and recreates ALB if it was deleted by stop.sh.
set -euo pipefail

[ -f "$(dirname "$0")/.env" ] && source "$(dirname "$0")/.env"

STATE_FILE=".state"
[ -f "$STATE_FILE" ] || { echo "ERROR: .state not found. Run ./create.sh first." >&2; exit 1; }
source "$STATE_FILE"

# ── start instances ───────────────────────────────────────────────────────────
instance_state() {
    aws ec2 describe-instances --region "$REGION" --instance-ids "$1" \
        --query 'Reservations[0].Instances[0].State.Name' --output text
}

STATE_1=$(instance_state "$INSTANCE_1_ID")
STATE_2=$(instance_state "$INSTANCE_2_ID")

TO_START=()
[ "$STATE_1" = "stopped" ] && TO_START+=("$INSTANCE_1_ID")
[ "$STATE_2" = "stopped" ] && TO_START+=("$INSTANCE_2_ID")

if [ ${#TO_START[@]} -gt 0 ]; then
    echo "Starting instances: ${TO_START[*]} ..."
    aws ec2 start-instances --region "$REGION" --instance-ids "${TO_START[@]}" >/dev/null
    aws ec2 wait instance-running --region "$REGION" --instance-ids "${TO_START[@]}"
    echo "Instances running."
else
    echo "Instances already running."
fi

# ── recreate ALB if deleted ───────────────────────────────────────────────────
if [ -n "${ALB_ARN:-}" ]; then
    echo "ALB already exists: $ALB_ARN"
else
    echo "Recreating ALB..."

    ALB_ARN=$(aws elbv2 create-load-balancer \
        --region "$REGION" \
        --name "troubleshoot-alb" \
        --subnets "$SUBNET_A_ID" "$SUBNET_B_ID" \
        --security-groups "$ALB_SG_ID" \
        --scheme internet-facing \
        --type application \
        --query 'LoadBalancers[0].LoadBalancerArn' --output text)
    echo "  ALB: $ALB_ARN"

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
    echo "  TG:  $TG_ARN"

    aws elbv2 register-targets \
        --region "$REGION" --target-group-arn "$TG_ARN" \
        --targets "Id=$INSTANCE_1_ID" "Id=$INSTANCE_2_ID" >/dev/null

    LISTENER_ARN=$(aws elbv2 create-listener \
        --region "$REGION" \
        --load-balancer-arn "$ALB_ARN" \
        --protocol HTTP --port 80 \
        --default-actions "Type=forward,TargetGroupArn=$TG_ARN" \
        --query 'Listeners[0].ListenerArn' --output text)
    echo "  Listener: $LISTENER_ARN"

    echo "Waiting for ALB to become active..."
    aws elbv2 wait load-balancer-available \
        --region "$REGION" --load-balancer-arns "$ALB_ARN"

    # append new ARNs to .state
    cat >> "$STATE_FILE" << EOF
ALB_ARN=$ALB_ARN
TG_ARN=$TG_ARN
LISTENER_ARN=$LISTENER_ARN
EOF
    echo "ALB ready."
fi

# ── print connection info ─────────────────────────────────────────────────────
ALB_DNS=$(aws elbv2 describe-load-balancers --region "$REGION" \
    --load-balancer-arns "$ALB_ARN" \
    --query 'LoadBalancers[0].DNSName' --output text)
IP_1=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$INSTANCE_1_ID" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
IP_2=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$INSTANCE_2_ID" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)

echo ""
echo "App (ALB): http://$ALB_DNS"
echo "SSH-1:     ssh -i ${KEY_NAME}.pem -o IdentitiesOnly=yes ec2-user@${IP_1}"
echo "SSH-2:     ssh -i ${KEY_NAME}.pem -o IdentitiesOnly=yes ec2-user@${IP_2}"
