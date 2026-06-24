#!/bin/bash
# Stops both instances and deletes ALB (compute + ALB billing stops).
# EBS: ~$1.28/mo continues. Everything else is free.
set -euo pipefail

[ -f "$(dirname "$0")/.env" ] && source "$(dirname "$0")/.env"

STATE_FILE=".state"
[ -f "$STATE_FILE" ] || { echo "ERROR: .state not found. Run ./create.sh first." >&2; exit 1; }
source "$STATE_FILE"

# ── stop instances ────────────────────────────────────────────────────────────
instance_state() {
    aws ec2 describe-instances --region "$REGION" --instance-ids "$1" \
        --query 'Reservations[0].Instances[0].State.Name' --output text
}

STATE_1=$(instance_state "$INSTANCE_1_ID")
STATE_2=$(instance_state "$INSTANCE_2_ID")
echo "Instance-1: $STATE_1   Instance-2: $STATE_2"

TO_STOP=()
[ "$STATE_1" = "running" ] && TO_STOP+=("$INSTANCE_1_ID")
[ "$STATE_2" = "running" ] && TO_STOP+=("$INSTANCE_2_ID")

if [ ${#TO_STOP[@]} -gt 0 ]; then
    echo "Stopping instances..."
    aws ec2 stop-instances --region "$REGION" --instance-ids "${TO_STOP[@]}" >/dev/null
    aws ec2 wait instance-stopped --region "$REGION" --instance-ids "${TO_STOP[@]}"
    echo "Instances stopped."
else
    echo "Instances already stopped."
fi

# ── delete ALB stack (listener → target group → ALB) ─────────────────────────
if [ -z "${ALB_ARN:-}" ]; then
    echo "ALB already deleted."
    exit 0
fi

echo "Deleting ALB..."
aws elbv2 delete-listener  --region "$REGION" --listener-arn   "$LISTENER_ARN" 2>/dev/null || true
aws elbv2 delete-target-group --region "$REGION" --target-group-arn "$TG_ARN"  2>/dev/null || true
aws elbv2 delete-load-balancer --region "$REGION" --load-balancer-arn "$ALB_ARN"

echo "Waiting for ALB to be deleted..."
until ! aws elbv2 describe-load-balancers \
        --region "$REGION" --load-balancer-arns "$ALB_ARN" \
        --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null | grep -q arn; do
    sleep 5
done
echo "ALB deleted."

# ── update .state: remove ALB fields ─────────────────────────────────────────
python3 - "$STATE_FILE" << 'PYEOF'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
lines = [l for l in p.read_text().splitlines()
         if not l.startswith(("ALB_ARN=", "TG_ARN=", "LISTENER_ARN="))]
p.write_text("\n".join(lines) + "\n")
PYEOF

echo ""
echo "Stopped. Remaining charges: 2x EBS ~\$1.28/mo total."
echo "Run ./start.sh to bring it back up."
