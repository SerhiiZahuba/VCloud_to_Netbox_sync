#!/bin/bash
#set -x

CLOUD_URL="https://cloud_url"
CLOUD_TOKEN="TOKEN"
NETBOX_URL="https://netbox.example.com/api"
NETBOX_TOKEN="TOKEN"

NETBOX_SITE=47
NETBOX_CLUSTER=83
NETBOX_ROLE=8
NETBOX_TENANT=10
NETBOX_PLATFORM=5
SYNC_TEMPLATES=false

LOG_FILE="sync_vms.log"

touch "$LOG_FILE"

# ==================================

log() {
    echo "[$(date '+%F %T')] $1" | tee -a "$LOG_FILE"
}


# --- Check access to vCloud ---
VCLOUD_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Accept: application/*+json;version=38.1" -H "Authorization: Bearer $CLOUD_TOKEN" \
    "$CLOUD_URL/api/query?type=vm&page=1&pageSize=1&format=records")

if [ "$VCLOUD_STATUS" -ne 200 ]; then
    log "❌ Помилка: немає доступу до vCloud (код $VCLOUD_STATUS)"
    exit 1
fi

log "✅ Connect to vCloud successful"

# --- Check access to NetBox ---
NB_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: Token $NETBOX_TOKEN" "$NETBOX_URL/")

if [ "$NB_STATUS" -ne 200 ]; then
    log "❌ Помилка: немає доступу до NetBox (код $NB_STATUS)"
    exit 1
fi

log "✅ Connect to NetBox successful"

# --- Функції роботи з NetBox ---
create_vm() {
    local NAME="$1"
    local STATUS="$2"
    local CPU="$3"
    local RAM="$4"
    local IP="$5"
    local EXT_IP="$6"
    local MAC="$7"
    local NET="$8"
    local DISK="$9"

    RESP=$(curl -s -w "\n%{http_code}" -X POST "$NETBOX_URL/virtualization/virtual-machines/" \
        -H "Authorization: Token $NETBOX_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{
            \"name\": \"$NAME\",
            \"status\": \"active\",
            \"site\": $NETBOX_SITE,
            \"cluster\": $NETBOX_CLUSTER,
            \"role\": $NETBOX_ROLE,
            \"tenant\": $NETBOX_TENANT,
            \"platform\": $NETBOX_PLATFORM,
            \"vcpus\": $CPU,
            \"memory\": $RAM,
            \"disk\": $DISK,
            \"comments\": \"auto sync from cloud\",
            \"local_context_data\": {
                \"ip_address\": \"$IP\",
                \"external_ip\": \"$EXT_IP\",
                \"mac\": \"$MAC\",
                \"network\": \"$NET\",
                \"cloud_status\": \"$STATUS\"
            }
        }")

    BODY=$(echo "$RESP" | head -n -1)
    CODE=$(echo "$RESP" | tail -n1)

    if [ "$CODE" -ne 201 ]; then
        log "❌ Помилка створення VM $NAME (код $CODE): $BODY"
        echo ""
    else
        echo "$BODY" | jq -r '.id'
    fi
}


create_interface() {
    local VM_ID="$1"

    RESP=$(curl -s -X POST "$NETBOX_URL/virtualization/interfaces/" \
        -H "Authorization: Token $NETBOX_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{
            \"virtual_machine\": $VM_ID,
            \"name\": \"eth0\",
            \"enabled\": true,
            \"mtu\": 65536,
            \"mode\": \"access\"
        }")

    echo "$RESP" | jq -r '.id'
}

create_ip() {
    local IFACE_ID="$1"
    local IP="$2"

    RESP=$(curl -s -X POST "$NETBOX_URL/ipam/ip-addresses/" \
        -H "Authorization: Token $NETBOX_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{
            \"status\": \"active\",
            \"assigned_object_type\": \"virtualization.vminterface\",
            \"assigned_object_id\": $IFACE_ID,
            \"address\": \"$IP/24\",
            \"family\": 4
        }")

    echo "$RESP" | jq -r '.id'
}

# --- Main cycle VM ---
PAGE=1
while :; do
    RESP=$(curl -s -H "Accept: application/*+json;version=38.1" -H "Authorization: Bearer $CLOUD_TOKEN" \
        "$CLOUD_URL/api/query?type=vm&page=$PAGE&pageSize=25&format=records")

    VM_LIST=$(echo "$RESP" | jq -c '.record[]?')
    if [ -z "$VM_LIST" ]; then
        break
    fi

    echo "$VM_LIST" | while read -r vm; do
        NAME=$(echo "$vm" | jq -r '.name')
        STATUS=$(echo "$vm" | jq -r '.status')
        HREF=$(echo "$vm" | jq -r '.href')
        CPU=$(echo "$vm" | jq -r '.numberOfCpus // 0')
        RAM=$(echo "$vm" | jq -r '.memoryMB // 0')
        DISK=$(echo "$vm" | jq -r '.totalStorageAllocatedMb')
        IS_TEMPLATE=$(echo "$vm" | jq -r '.isVAppTemplate')

        if [ "$IS_TEMPLATE" = "true" ] && [ "$SYNC_TEMPLATES" != "true" ]; then
                    log "⏭ Template omitted $NAME (isVAppTemplate=true)"
                    continue
                fi

        DETAILS=$(curl -s -H "Accept: application/*+json;version=38.1" -H "Authorization: Bearer $CLOUD_TOKEN" "$HREF")

        echo "$DETAILS" | jq -c '.section[]? | select(._type=="NetworkConnectionSectionType") | .networkConnection[]?' | while read -r conn; do
            IP=$(echo "$conn" | jq -r '.ipAddress // ""')
            EXT_IP=$(echo "$conn" | jq -r '.externalIpAddress // ""')
            MAC=$(echo "$conn" | jq -r '.macAddress // ""')
            NET=$(echo "$conn" | jq -r '.network // ""')

            log "↘️ vCloud: $NAME | $STATUS | CPU:$CPU | RAM:$RAM | IP:$IP | Ext:$EXT_IP | MAC:$MAC | Net:$NET | Disk:$DISK"

            VM_ID=$(create_vm "$NAME" "$STATUS" "$CPU" "$RAM" "$IP" "$EXT_IP" "$MAC" "$NET" "$DISK")
            log "✅ Create VM $NAME (ID: $VM_ID)"

            IFACE_ID=$(create_interface "$VM_ID")
            log "✅ Додано інтерфейс до VM $NAME (Iface ID: $IFACE_ID)"

            if [ -n "$IP" ]; then
                IP_ID=$(create_ip "$IFACE_ID" "$IP")
                log "✅ Призначено Internal IP $IP (IP ID: $IP_ID)"
            fi

            if [ -n "$EXT_IP" ]; then
                EXT_IP_ID=$(create_ip "$IFACE_ID" "$EXT_IP")
                log "✅ Призначено External IP $EXT_IP (IP ID: $EXT_IP_ID)"
            fi
        done

        sleep 1
    done

    PAGE=$((PAGE+1))
done

log "=== Sync complite ==="
