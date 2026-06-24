#!/bin/bash
# Destroys all AWS resources in reverse order. Removes .state on success.
set -euo pipefail

[ -f "$(dirname "$0")/.env" ] && source "$(dirname "$0")/.env"

STATE_FILE=".state"
[ -f "$STATE_FILE" ] || { echo "ERROR: .state not found. Nothing to delete." >&2; exit 1; }
source "$STATE_FILE"

echo "This will permanently delete:"
echo "  ALB:          ${ALB_ARN:-already deleted}"
echo "  Target group: ${TG_ARN:-already deleted}"
echo "  Instance-1:   $INSTANCE_1_ID  volume: $VOLUME_1_ID"
echo "  Instance-2:   $INSTANCE_2_ID  volume: $VOLUME_2_ID"
echo "  EC2 SG:       $EC2_SG_ID"
echo "  ALB SG:       $ALB_SG_ID"
echo "  Route table:  $RTB_ID"
echo "  Subnet-a:     $SUBNET_A_ID"
echo "  Subnet-b:     $SUBNET_B_ID"
echo "  IGW:          $IGW_ID"
echo "  VPC:          $VPC_ID"
echo "  Key pair:     $KEY_NAME"
echo ""
read -r -p "Type 'yes' to confirm: " CONFIRM
[ "$CONFIRM" = "yes" ] || { echo "Aborted."; exit 0; }
echo ""

# ── ALB: listener → target group → load balancer (skip if stop.sh already did this) ──
if [ -n "${ALB_ARN:-}" ]; then
    echo "[-] Deleting ALB resources..."
    aws elbv2 delete-listener     --region "$REGION" --listener-arn      "$LISTENER_ARN" 2>/dev/null || true
    aws elbv2 delete-target-group --region "$REGION" --target-group-arn  "$TG_ARN"       2>/dev/null || true
    aws elbv2 delete-load-balancer --region "$REGION" --load-balancer-arn "$ALB_ARN"
    echo "    Waiting for ALB to be deleted..."
    until ! aws elbv2 describe-load-balancers \
            --region "$REGION" --load-balancer-arns "$ALB_ARN" \
            --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null | grep -q arn; do
        sleep 5
    done
    echo "    Done."
else
    echo "[-] ALB already deleted (by stop.sh) — skipping."
fi

# ── spot requests ─────────────────────────────────────────────────────────────
echo "[-] Cancelling spot requests..."
for IID in "$INSTANCE_1_ID" "$INSTANCE_2_ID"; do
    SIR=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$IID" \
        --query 'Reservations[0].Instances[0].SpotInstanceRequestId' \
        --output text 2>/dev/null || true)
    if [ -n "$SIR" ] && [ "$SIR" != "None" ]; then
        aws ec2 cancel-spot-instance-requests \
            --region "$REGION" --spot-instance-request-ids "$SIR" >/dev/null
        echo "    Cancelled: $SIR"
    fi
done

# ── instances ─────────────────────────────────────────────────────────────────
echo "[-] Terminating instances..."
aws ec2 terminate-instances \
    --region "$REGION" \
    --instance-ids "$INSTANCE_1_ID" "$INSTANCE_2_ID" >/dev/null
echo "    Waiting for termination..."
aws ec2 wait instance-terminated \
    --region "$REGION" --instance-ids "$INSTANCE_1_ID" "$INSTANCE_2_ID"
echo "    Done."

# ── volumes (DeleteOnTermination=false for persistent spot) ───────────────────
echo "[-] Deleting EBS volumes..."
for VID in "$VOLUME_1_ID" "$VOLUME_2_ID"; do
    aws ec2 delete-volume --region "$REGION" --volume-id "$VID" 2>/dev/null \
        && echo "    Deleted: $VID" \
        || echo "    $VID not found (already deleted?)"
done

# ── security groups ───────────────────────────────────────────────────────────
echo "[-] Deleting EC2 security group $EC2_SG_ID ..."
aws ec2 delete-security-group --region "$REGION" --group-id "$EC2_SG_ID"

echo "[-] Deleting ALB security group $ALB_SG_ID ..."
aws ec2 delete-security-group --region "$REGION" --group-id "$ALB_SG_ID"

# ── route table ───────────────────────────────────────────────────────────────
echo "[-] Deleting route table $RTB_ID ..."
aws ec2 disassociate-route-table \
    --region "$REGION" --association-id "$RTB_ASSOC_A_ID" 2>/dev/null || true
aws ec2 disassociate-route-table \
    --region "$REGION" --association-id "$RTB_ASSOC_B_ID" 2>/dev/null || true
aws ec2 delete-route-table --region "$REGION" --route-table-id "$RTB_ID"

# ── subnets ───────────────────────────────────────────────────────────────────
echo "[-] Deleting subnets..."
aws ec2 delete-subnet --region "$REGION" --subnet-id "$SUBNET_A_ID"
aws ec2 delete-subnet --region "$REGION" --subnet-id "$SUBNET_B_ID"

# ── internet gateway ──────────────────────────────────────────────────────────
echo "[-] Deleting internet gateway $IGW_ID ..."
aws ec2 detach-internet-gateway \
    --region "$REGION" --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"
aws ec2 delete-internet-gateway --region "$REGION" --internet-gateway-id "$IGW_ID"

# ── vpc ───────────────────────────────────────────────────────────────────────
echo "[-] Deleting VPC $VPC_ID ..."
aws ec2 delete-vpc --region "$REGION" --vpc-id "$VPC_ID"

# ── key pair ──────────────────────────────────────────────────────────────────
echo "[-] Deleting key pair '$KEY_NAME'..."
aws ec2 delete-key-pair --region "$REGION" --key-name "$KEY_NAME"
rm -f "${KEY_NAME}.pem" && echo "    Local ${KEY_NAME}.pem removed."

rm -f "$STATE_FILE"
echo ""
echo "All resources deleted."
