#!/bin/bash
#set -x

VCLOUD_USER="apiuser@ORG"
VCLOUD_PASS="apipassuser"
VCLOUD_HOST="https://cloud_host"

NETBOX_URL="https://netbox.example.com/api"
NETBOX_TOKEN="TOKEN"

NETBOX_SITE=47
NETBOX_CLUSTER=83
NETBOX_ROLE=8
NETBOX_TENANT=10
NETBOX_PLATFORM=5
SYNC_TEMPLATES=false
SYNC_POWEROFF=false

LOG_FILE="sync_vms.log"

touch "$LOG_FILE"

# ==================================

log() {
    echo "[$(date '+%F %T')] $1" | tee -a "$LOG_FILE"
}


get_vcloud_token() {
  local creds
  creds=$(echo -n "${VCLOUD_USER}:${VCLOUD_PASS}" | base64)

  RESPONSE_HEADERS=$(mktemp)
  curl -s -D "$RESPONSE_HEADERS" \
       -X POST \
       -H "Authorization: Basic $creds" \
       -H "Accept: application/*;version=38.1" \
       "${VCLOUD_HOST}/cloudapi/1.0.0/sessions" -o /dev/null

  VCLOUD_TOKEN=$(grep -i "X-VMWARE-VCLOUD-ACCESS-TOKEN" "$RESPONSE_HEADERS" | awk '{print $2}' | tr -d '\r\n')
  rm -f "$RESPONSE_HEADERS"

  if [ -z "$VCLOUD_TOKEN" ]; then
    log "❌ Не вдалося отримати токен vCloud"
    exit 1
  else
    log "✅ Отримано токен vCloud"
  fi
}


# --- Викликаємо отримання токена ---
get_vcloud_token

# --- Перевірка доступу до vCloud ---
VCLOUD_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Accept: application/*+json;version=38.1" -H "Authorization: Bearer $VCLOUD_TOKEN" \
    "$VCLOUD_HOST/api/query?type=vm&page=1&pageSize=1&format=records")

if [ "$VCLOUD_STATUS" -ne 200 ]; then
    log "❌ Помилка: немає доступу до vCloud (код $VCLOUD_STATUS)"
    exit 1
fi

log "✅ Підключення до vCloud успішне"




# --- Перевірка доступу до NetBox ---
NB_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: Token $NETBOX_TOKEN" "$NETBOX_URL/")

if [ "$NB_STATUS" -ne 200 ]; then
    log "❌ Помилка: немає доступу до NetBox (код $NB_STATUS)"
    exit 1
fi

log "✅ Підключення до NetBox успішне"


# --- Функції роботи з NetBox ---
find_vm_in_netbox() {
    local NAME="$1"
    RESP=$(curl -s -H "Authorization: Token $NETBOX_TOKEN" \
        "$NETBOX_URL/virtualization/virtual-machines/?name=$NAME")
    echo "$RESP" | jq -r '.results[0].id // empty'
}


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


update_vm() {
    local VM_ID="$1"
    local STATUS="$2"
    local CPU="$3"
    local RAM="$4"
    local DISK="$5"
    local IP="$6"
    local EXT_IP="$7"
    local MAC="$8"
    local NET="$9"

    RESP=$(curl -s -X PATCH "$NETBOX_URL/virtualization/virtual-machines/$VM_ID/" \
        -H "Authorization: Token $NETBOX_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{
            \"status\": \"active\",
            \"vcpus\": $CPU,
            \"memory\": $RAM,
            \"disk\": $DISK,
            \"local_context_data\": {
                \"ip_address\": \"$IP\",
                \"external_ip\": \"$EXT_IP\",
                \"mac\": \"$MAC\",
                \"network\": \"$NET\",
                \"cloud_status\": \"$STATUS\"
            }
        }")

    echo "$RESP" | jq -r '.id // empty'
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

# --- Основний цикл по VM ---
PAGE=1
while :; do
    RESP=$(curl -s -H "Accept: application/*+json;version=38.1" -H "Authorization: Bearer $VCLOUD_TOKEN" \
        "$VCLOUD_HOST/api/query?type=vm&page=$PAGE&pageSize=25&format=records")

    VM_LIST=$(echo "$RESP" | jq -c '.record[]?')
    [ -z "$VM_LIST" ] && break

    echo "$VM_LIST" | while read -r vm; do
        NAME=$(echo "$vm" | jq -r '.name')
        STATUS=$(echo "$vm" | jq -r '.status')
        HREF=$(echo "$vm" | jq -r '.href')
        CPU=$(echo "$vm" | jq -r '.numberOfCpus // 0')
        RAM=$(echo "$vm" | jq -r '.memoryMB // 0')
        DISK=$(echo "$vm" | jq -r '.totalStorageAllocatedMb // 0')
        IS_TEMPLATE=$(echo "$vm" | jq -r '.isVAppTemplate')

        # Фільтри
        [ "$IS_TEMPLATE" = "true" ] && [ "$SYNC_TEMPLATES" != "true" ] && { log "⏭ Пропущено шаблон $NAME"; continue; }
        [ "$STATUS" = "POWERED_OFF" ] && [ "$SYNC_POWEROFF" != "true" ] && { log "⏭ Пропущено вимкнену VM $NAME"; continue; }

        DETAILS=$(curl -s -H "Accept: application/*+json;version=38.1" -H "Authorization: Bearer $VCLOUD_TOKEN" "$HREF")

        echo "$DETAILS" | jq -c '.section[]? | select(._type=="NetworkConnectionSectionType") | .networkConnection[]?' | while read -r conn; do
            IP=$(echo "$conn" | jq -r '.ipAddress // ""')
            EXT_IP=$(echo "$conn" | jq -r '.externalIpAddress // ""')
            MAC=$(echo "$conn" | jq -r '.macAddress // ""')
            NET=$(echo "$conn" | jq -r '.network // ""')

            log "↘️ vCloud: $NAME | $STATUS | CPU:$CPU | RAM:$RAM | Disk:$DISK | IP:$IP | Ext:$EXT_IP | MAC:$MAC | Net:$NET"

            # Шукаємо у NetBox
            VM_ID=$(find_vm_in_netbox "$NAME")
            if [ -z "$VM_ID" ]; then
                VM_ID=$(create_vm "$NAME" "$STATUS" "$CPU" "$RAM" "$IP" "$EXT_IP" "$MAC" "$NET" "$DISK")
                log "🆕 Створено VM $NAME (ID: $VM_ID)"
            else
                update_vm "$VM_ID" "$STATUS" "$CPU" "$RAM" "$DISK" "$IP" "$EXT_IP" "$MAC" "$NET"
                log "♻️ Оновлено VM $NAME (ID: $VM_ID)"
            fi

            # Додаємо інтерфейс, якщо нова VM
            IFACE_ID=$(create_interface "$VM_ID")
            [ -n "$IFACE_ID" ] && log "✅ Додано інтерфейс (Iface ID: $IFACE_ID)"

            # Прив'язуємо IP
            [ -n "$IP" ] && { IP_ID=$(create_ip "$IFACE_ID" "$IP"); log "✅ Призначено IP $IP (ID: $IP_ID)"; }
            [ -n "$EXT_IP" ] && { EXT_IP_ID=$(create_ip "$IFACE_ID" "$EXT_IP"); log "✅ Призначено External IP $EXT_IP (ID: $EXT_IP_ID)"; }
        done

        sleep 1
    done

    PAGE=$((PAGE+1))
done

log "=== Синхронізація завершена ==="
