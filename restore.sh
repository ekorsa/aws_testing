#!/bin/bash
# Restores whatever break.sh broke. Reads .break_state to know what to fix.
set -euo pipefail

[ -f "$(dirname "$0")/.env" ] && source "$(dirname "$0")/.env"

STATE_FILE=".state"
BREAK_FILE=".break_state"

[ -f "$STATE_FILE" ]  || { echo "ERROR: .state not found." >&2; exit 1; }
[ -f "$BREAK_FILE" ]  || { echo "Nothing to restore (.break_state not found)." >&2; exit 1; }
source "$STATE_FILE"
source "$BREAK_FILE"

echo "Restoring scenario: $SCENARIO"
echo ""

case "$SCENARIO" in

    alb_sg_block_http)
        echo "[+] Re-adding HTTP inbound to ALB security group $ALB_SG_ID ..."
        aws ec2 authorize-security-group-ingress \
            --region "$REGION" --group-id "$ALB_SG_ID" \
            --protocol tcp --port 80 --cidr "0.0.0.0/0"
        ;;

    ec2_sg_block_alb)
        echo "[+] Re-adding ALB → EC2 port 80 rule to $EC2_SG_ID ..."
        aws ec2 authorize-security-group-ingress \
            --region "$REGION" --group-id "$EC2_SG_ID" \
            --protocol tcp --port 80 \
            --source-group "$ALB_SG_ID"
        ;;

    tg_deregister_all)
        echo "[+] Re-registering instances to target group $TG_ARN ..."
        aws elbv2 register-targets \
            --region "$REGION" --target-group-arn "$TG_ARN" \
            --targets "Id=$INSTANCE_1_ID" "Id=$INSTANCE_2_ID"
        echo "    Waiting for at least one target to become healthy (~30s)..."
        SECONDS_WAITED=0
        until aws elbv2 describe-target-health \
                --region "$REGION" --target-group-arn "$TG_ARN" \
                --query 'TargetHealthDescriptions[?TargetHealth.State==`healthy`]' \
                --output text 2>/dev/null | grep -q .; do
            sleep 5
            SECONDS_WAITED=$((SECONDS_WAITED + 5))
            [ $SECONDS_WAITED -lt 120 ] || { echo "Timed out waiting for healthy target."; break; }
        done
        ;;

    rtb_drop_default_route)
        echo "[+] Re-adding 0.0.0.0/0 → IGW route to $RTB_ID ..."
        aws ec2 create-route \
            --region "$REGION" \
            --route-table-id "$RTB_ID" \
            --destination-cidr-block "0.0.0.0/0" \
            --gateway-id "$IGW_ID"
        ;;

    igw_detach)
        echo "[+] Re-attaching Internet Gateway $IGW_ID to VPC $VPC_ID ..."
        aws ec2 attach-internet-gateway \
            --region "$REGION" \
            --internet-gateway-id "$IGW_ID" \
            --vpc-id "$VPC_ID"
        ;;

    nacl_deny_http)
        echo "[+] Removing NACL deny rule (rule 1, port 80) from $NACL_ID ..."
        aws ec2 delete-network-acl-entry \
            --region "$REGION" \
            --network-acl-id "$NACL_ID" \
            --ingress \
            --rule-number 1
        ;;

    stop_instance_1)
        echo "[+] Starting instance-1 $INSTANCE_1_ID ..."
        aws ec2 start-instances --region "$REGION" --instance-ids "$INSTANCE_1_ID" >/dev/null
        echo "    Waiting for running state..."
        aws ec2 wait instance-running --region "$REGION" --instance-ids "$INSTANCE_1_ID"
        ;;

    *)
        echo "ERROR: unknown scenario '$SCENARIO'" >&2
        exit 1
        ;;
esac

rm -f "$BREAK_FILE"
echo ""
echo "Restored. Run ./status.sh to verify."
