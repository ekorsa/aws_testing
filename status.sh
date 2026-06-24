#!/bin/bash
# Shows state of all resources, target health, app health check, and cost estimate.
# Works in all states: running, stopped (ALB deleted), deleted.
set -euo pipefail

[ -f "$(dirname "$0")/.env" ] && source "$(dirname "$0")/.env"

STATE_FILE=".state"
BREAK_FILE=".break_state"

[ -f "$STATE_FILE" ] || { echo "No environment found. Run ./create.sh first."; exit 0; }
source "$STATE_FILE"

instance_info() {
    aws ec2 describe-instances --region "$REGION" --instance-ids "$1" \
        --query 'Reservations[0].Instances[0].{State:State.Name,IP:PublicIpAddress,AZ:Placement.AvailabilityZone}' \
        --output json
}

# ── ALB (может быть удалён stop.sh) ──────────────────────────────────────────
echo "=== ALB ==="
if [ -z "${ALB_ARN:-}" ]; then
    echo "State:  deleted (run ./start.sh to recreate)"
else
    ALB_DNS=$(aws elbv2 describe-load-balancers --region "$REGION" \
        --load-balancer-arns "$ALB_ARN" \
        --query 'LoadBalancers[0].DNSName' --output text 2>/dev/null || echo "not found")
    ALB_STATE=$(aws elbv2 describe-load-balancers --region "$REGION" \
        --load-balancer-arns "$ALB_ARN" \
        --query 'LoadBalancers[0].State.Code' --output text 2>/dev/null || echo "not found")
    echo "State:  $ALB_STATE"
    echo "DNS:    $ALB_DNS"
    [ "$ALB_STATE" = "active" ] && echo "App:    http://$ALB_DNS"
fi

# ── instances ─────────────────────────────────────────────────────────────────
echo ""
echo "=== Instances ==="

# spot request states для обоих инстансов одним запросом
SPOT_JSON=$(aws ec2 describe-spot-instance-requests \
    --region "$REGION" \
    --filters "Name=instance-id,Values=${INSTANCE_1_ID},${INSTANCE_2_ID}" \
    --query 'SpotInstanceRequests[*].{id:InstanceId,state:State,status:Status.Code}' \
    --output json 2>/dev/null || echo "[]")

spot_status() {
    local iid="$1"
    echo "$SPOT_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
rec = next((r for r in data if r['id'] == '$iid'), None)
if rec:
    state  = rec['state']   # open | active | disabled | cancelled | closed
    status = rec['status']  # instance-stopped-by-user | instance-running | marked-for-stop | ...
    # человекочитаемая интерпретация
    note = {
        'instance-running':          'running (spot active)',
        'instance-stopped-by-user':  'stopped by user — AWS не перезапустит',
        'marked-for-stop':           '⚠ AWS прерывает — остановка через 2 мин',
        'marked-for-termination':    '⚠ AWS прерывает — terminate через 2 мин',
        'instance-terminated-by-user': 'terminated by user',
    }.get(status, status)
    print(f'{state} / {note}')
else:
    print('spot info unavailable')
"
}

for N in 1 2; do
    IID_VAR="INSTANCE_${N}_ID"
    IID="${!IID_VAR}"
    INFO=$(instance_info "$IID")
    STATE=$(echo "$INFO" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d['State'])")
    IP=$(echo    "$INFO" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d['IP'] or 'none')")
    AZ=$(echo    "$INFO" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d['AZ'])")
    SPOT=$(spot_status "$IID")
    echo "Instance-$N ($AZ): $IID"
    echo "  state=$STATE  ip=$IP"
    echo "  spot: $SPOT"
    if [ "$STATE" = "running" ] && [ "$IP" != "none" ]; then
        echo "  SSH: ssh -i ${KEY_NAME}.pem -o IdentitiesOnly=yes ec2-user@${IP}"
    fi
done

# ── target group health (только если ALB есть) ────────────────────────────────
echo ""
echo "=== Target Group Health ==="
if [ -z "${TG_ARN:-}" ]; then
    echo "(ALB deleted — no target group)"
else
    aws elbv2 describe-target-health \
        --region "$REGION" --target-group-arn "$TG_ARN" \
        --query 'TargetHealthDescriptions[*].{Target:Target.Id,State:TargetHealth.State,Reason:TargetHealth.Reason}' \
        --output table 2>/dev/null || echo "not available"
fi

# ── app health check (только если ALB активен) ────────────────────────────────
echo ""
echo "=== App Health Check ==="
if [ -n "${ALB_ARN:-}" ] && [ "${ALB_STATE:-}" = "active" ]; then
    echo -n "http://$ALB_DNS/health ... "
    if curl -sf --max-time 5 "http://$ALB_DNS/health" >/dev/null 2>&1; then
        echo "OK"
    else
        echo "FAIL"
    fi
else
    echo "(ALB not active)"
fi

# ── break state ───────────────────────────────────────────────────────────────
if [ -f "$BREAK_FILE" ]; then
    source "$BREAK_FILE"
    echo ""
    echo "=== Break State ==="
    echo "BROKEN: scenario '$SCENARIO' active. Run ./restore.sh to fix."
fi

# ── cost estimate ─────────────────────────────────────────────────────────────
echo ""
echo "=== Cost Estimate (us-east-1) ==="
echo "  Running:  2x t4g.micro spot + 2x EBS + 2x IPv4 + ALB  ≈ \$0.025/hr (\$0.60/day)"
echo "  Stopped:  2x EBS only (ALB удалён stop.sh)             ≈ \$1.28/mo"
echo "  Deleted:  \$0"

# ── isolation note ────────────────────────────────────────────────────────────
echo ""
echo "=== Isolation ==="
echo "  Все скрипты работают только с ID из .state — другие ресурсы не затрагиваются."
echo "  VPC: $VPC_ID  |  SG-ALB: $ALB_SG_ID  |  SG-EC2: $EC2_SG_ID"
