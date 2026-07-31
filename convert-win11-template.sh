#!/usr/bin/env bash

set -Eeuo pipefail

VM_ID="${1:-777}"
TEMPLATE_NAME="${2:-Win11-Golden}"
WAIT_SECONDS="${WAIT_SECONDS:-900}"
CHECK_INTERVAL="${CHECK_INTERVAL:-10}"

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

fail() {
    log "ERROR: $*"
    exit 1
}

command -v qm >/dev/null 2>&1 ||
    fail "The qm command was not found. Run this script on a Proxmox node."

qm status "$VM_ID" >/dev/null 2>&1 ||
    fail "VM $VM_ID does not exist."

CURRENT_STATUS="$(qm status "$VM_ID" | awk '{print $2}')"

if [[ "$CURRENT_STATUS" == "template" ]]; then
    fail "VM $VM_ID is already a template."
fi

log "Waiting for VM $VM_ID to shut down after Sysprep..."

elapsed=0

while true; do
    status="$(qm status "$VM_ID" | awk '{print $2}')"

    if [[ "$status" == "stopped" ]]; then
        break
    fi

    if (( elapsed >= WAIT_SECONDS )); then
        fail "Timed out after ${WAIT_SECONDS}s waiting for VM $VM_ID to stop."
    fi

    log "VM status is '$status'; checking again in ${CHECK_INTERVAL}s."
    sleep "$CHECK_INTERVAL"
    elapsed=$((elapsed + CHECK_INTERVAL))
done

log "Removing installation media references..."

config="$(qm config "$VM_ID")"

while IFS= read -r device; do
    [[ -z "$device" ]] && continue

    log "Setting $device to empty CD/DVD media."
    qm set "$VM_ID" "--${device}" "none,media=cdrom"
done < <(
    printf '%s\n' "$config" |
        awk -F: '
            /media=cdrom/ {
                gsub(/[[:space:]]/, "", $1)
                print $1
            }
        '
)

log "Enabling QEMU Guest Agent in the VM configuration..."
qm set "$VM_ID" --agent enabled=1

log "Setting boot order to the Windows system disk..."
qm set "$VM_ID" --boot order=scsi0

log "Renaming VM to '$TEMPLATE_NAME'..."
qm set "$VM_ID" --name "$TEMPLATE_NAME"

log "Converting VM $VM_ID into a Proxmox template..."
qm template "$VM_ID"

log "Template created successfully."
qm status "$VM_ID"
