#!/bin/bash
# Randomly breaks one AWS-side thing. Saves what was broken to .break_state.
# Run ./restore.sh to fix it.
set -euo pipefail

[ -f "$(dirname "$0")/.env" ] && source "$(dirname "$0")/.env"

STATE_FILE=".state"
BREAK_FILE=".break_state"

[ -f "$STATE_FILE" ]  || { echo "ERROR: .state not found. Run ./create.sh first." >&2; exit 1; }
[ ! -f "$BREAK_FILE" ] || { echo "ERROR: already broken (.break_state exists). Run ./restore.sh first." >&2; exit 1; }
source "$STATE_FILE"

# ── scenarios ─────────────────────────────────────────────────────────────────
# Each function breaks one AWS-level thing and writes .break_state.

scenario_alb_sg_block_http() {
    # Remove HTTP inbound from ALB Security Group.
    # Symptom: browser times out, curl hangs — ALB stops accepting port 80.
    aws ec2 revoke-security-group-ingress \
        --region "$REGION" --group-id "$ALB_SG_ID" \
        --protocol tcp --port 80 --cidr "0.0.0.0/0"
    echo "SCENARIO=alb_sg_block_http" > "$BREAK_FILE"
}

scenario_ec2_sg_block_alb() {
    # Remove the rule that allows ALB SG → EC2 port 80.
    # Symptom: ALB responds with 502 Bad Gateway. Health checks fail.
    aws ec2 revoke-security-group-ingress \
        --region "$REGION" --group-id "$EC2_SG_ID" \
        --protocol tcp --port 80 \
        --source-group "$ALB_SG_ID"
    echo "SCENARIO=ec2_sg_block_alb" > "$BREAK_FILE"
}

scenario_tg_deregister_all() {
    # Deregister both instances from the target group.
    # Symptom: ALB returns 503 Service Unavailable. Target group shows no targets.
    aws elbv2 deregister-targets \
        --region "$REGION" --target-group-arn "$TG_ARN" \
        --targets "Id=$INSTANCE_1_ID" "Id=$INSTANCE_2_ID"
    echo "SCENARIO=tg_deregister_all" > "$BREAK_FILE"
}

scenario_rtb_drop_default_route() {
    # Delete the 0.0.0.0/0 → IGW route from the route table.
    # Symptom: VPC completely unreachable — no SSH, no HTTP, ALB health checks fail.
    aws ec2 delete-route \
        --region "$REGION" --route-table-id "$RTB_ID" \
        --destination-cidr-block "0.0.0.0/0"
    echo "SCENARIO=rtb_drop_default_route" > "$BREAK_FILE"
}

scenario_igw_detach() {
    # Detach the Internet Gateway from the VPC.
    # Symptom: same as missing route — entire VPC goes dark. But root cause differs.
    aws ec2 detach-internet-gateway \
        --region "$REGION" \
        --internet-gateway-id "$IGW_ID" \
        --vpc-id "$VPC_ID"
    echo "SCENARIO=igw_detach" > "$BREAK_FILE"
}

scenario_nacl_deny_http() {
    # Add an explicit DENY for TCP port 80 inbound to the default NACL.
    # Symptom: same as SG block, but SG shows port 80 is allowed — teaches NACL vs SG.
    # NACLs are stateless and evaluated before SGs.
    NACL_ID=$(aws ec2 describe-network-acls \
        --region "$REGION" \
        --filters "Name=vpc-id,Values=$VPC_ID" "Name=default,Values=true" \
        --query 'NetworkAcls[0].NetworkAclId' --output text)
    aws ec2 create-network-acl-entry \
        --region "$REGION" \
        --network-acl-id "$NACL_ID" \
        --ingress \
        --rule-number 1 \
        --protocol tcp \
        --port-range From=80,To=80 \
        --cidr-block "0.0.0.0/0" \
        --rule-action deny
    printf "SCENARIO=nacl_deny_http\nNACL_ID=%s\n" "$NACL_ID" > "$BREAK_FILE"
}

scenario_stop_instance_1() {
    # Stop instance-1. ALB should route traffic only to instance-2.
    # Symptom: ALB still responds, but instance-1 is gone from target group.
    # Simulates a Spot interruption.
    aws ec2 stop-instances --region "$REGION" --instance-ids "$INSTANCE_1_ID" >/dev/null
    echo "SCENARIO=stop_instance_1" > "$BREAK_FILE"
}

# ── pick random scenario ───────────────────────────────────────────────────────
SCENARIOS=(
    scenario_alb_sg_block_http
    scenario_ec2_sg_block_alb
    scenario_tg_deregister_all
    scenario_rtb_drop_default_route
    scenario_igw_detach
    scenario_nacl_deny_http
    scenario_stop_instance_1
)

IDX=$(( RANDOM % ${#SCENARIOS[@]} ))
CHOSEN="${SCENARIOS[$IDX]}"

echo "Breaking environment..."
$CHOSEN
echo "Done. Something in AWS is now broken."
echo ""
echo "Diagnose with: ./status.sh  and  aws ec2/elbv2 commands"
echo "Restore with:  ./restore.sh"
