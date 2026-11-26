#!/usr/bin/env bash
# ==============================================================================
# arch-power.sh - Wake-on-LAN & safe shutdown controller with Dual-Boot
#                 detection (Arch Linux / Windows 11) for n8n + Ollama.
#
# Exit codes:
#   0 : Success (Arch Linux + Ollama ready, or shutdown completed / safely
#       aborted because a Hyprland/Wayland session is active or host is offline).
#   1 : Error, wake timeout, or invalid configuration.
#   2 : Other OS detected (Dual-Boot): host responds to ICMP ping, but both
#       SSH (22) and Ollama (11434) ports remain closed (e.g. Windows 11 active).
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "${SCRIPT_DIR}/../.env" ]; then
    set -a
    # shellcheck source=/dev/null
    source "${SCRIPT_DIR}/../.env"
    set +a
fi

ARCH_MAC="${ARCH_MAC_ADDRESS:-XX:XX:XX:XX:XX:XX}"
ARCH_IP="${ARCH_IP:-192.168.1.XXX}"
ARCH_OLLAMA_PORT="${ARCH_OLLAMA_PORT:-11434}"
ARCH_SSH_PORT="${ARCH_SSH_PORT:-22}"
ARCH_SSH_USER="${ARCH_SSH_USER:-archuser}"
ARCH_SSH_KEY="${ARCH_SSH_KEY:-}"
WOL_IFACE="${WOL_INTERFACE:-enp9s0}"
WOL_TIMEOUT_SEC="${WOL_TIMEOUT_SEC:-90}"
DUALBOOT_GRACE_SEC="${DUALBOOT_GRACE_SEC:-25}"
POLL_INTERVAL_SEC="${POLL_INTERVAL_SEC:-5}"

log() {
    printf '[%s] [ARCH-POWER] %s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "$*"
}

port_open() {
    local host="$1"
    local port="$2"

    if command -v nc &>/dev/null; then
        nc -z -w 2 "${host}" "${port}" &>/dev/null
        return $?
    fi

    timeout 2 bash -c "exec 3<>/dev/tcp/${host}/${port}" &>/dev/null
}

ping_host() {
    ping -c 1 -W 2 "${ARCH_IP}" &>/dev/null
}

validate_mac() {
    if [[ "${ARCH_MAC}" == "XX:XX:XX:XX:XX:XX" ]]; then
        log "ERROR: ARCH_MAC_ADDRESS is still set to placeholder (${ARCH_MAC}). Configure .env before use."
        return 1
    fi
    if [[ ! "${ARCH_MAC}" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]; then
        log "ERROR: Invalid MAC address '${ARCH_MAC}' (expected format XX:XX:XX:XX:XX:XX)."
        return 1
    fi
    return 0
}

validate_ip() {
    if [[ "${ARCH_IP}" == "192.168.1.XXX" || -z "${ARCH_IP}" ]]; then
        log "ERROR: ARCH_IP is still set to placeholder (${ARCH_IP}). Configure .env before use."
        return 1
    fi
    return 0
}

send_wol_packet() {
    validate_mac

    log "Sending Wake-on-LAN magic packet to ${ARCH_MAC} (interface ${WOL_IFACE})..."
    if command -v wakeonlan &>/dev/null; then
        wakeonlan "${ARCH_MAC}" >/dev/null
    elif command -v etherwake &>/dev/null; then
        etherwake -i "${WOL_IFACE}" "${ARCH_MAC}"
    elif command -v ether-wake &>/dev/null; then
        ether-wake -i "${WOL_IFACE}" "${ARCH_MAC}"
    elif command -v python3 &>/dev/null; then
        python3 - "${ARCH_MAC}" <<'PYEOF'
import socket
import sys

mac_hex = sys.argv[1].replace(":", "")
packet = b"\xff" * 6 + bytes.fromhex(mac_hex) * 16
with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    sock.sendto(packet, ("255.255.255.255", 9))
PYEOF
    else
        log "ERROR: No WoL utility available (wakeonlan, etherwake, ether-wake, or python3)."
        return 1
    fi
}

ssh_run_safe_shutdown() {
    local -a ssh_opts=(
        -o BatchMode=yes
        -o ConnectTimeout=5
        -o StrictHostKeyChecking=accept-new
        -p "${ARCH_SSH_PORT}"
    )

    if [ -n "${ARCH_SSH_KEY}" ] && [ -f "${ARCH_SSH_KEY}" ]; then
        ssh_opts+=(-i "${ARCH_SSH_KEY}")
    fi

    local output=""
    local rc=0
    output="$(ssh "${ssh_opts[@]}" "${ARCH_SSH_USER}@${ARCH_IP}" "sudo /usr/local/bin/safe-wol-shutdown" 2>&1)" || rc=$?

    if [ -n "${output}" ]; then
        log "Remote response: ${output}"
    fi

    if [[ "${output}" == *"ABORT_HYPRLAND_ACTIVE"* ]] || [[ "${output}" == *"ABORT_LOCK_FILE"* ]]; then
        log "Shutdown safely aborted (active graphical session or manual lock file present)."
        return 0
    fi

    if [ "${rc}" -eq 0 ] || [ "${rc}" -eq 255 ]; then
        # rc=255 may occur when systemctl poweroff terminates the SSH session immediately
        log "Remote shutdown triggered successfully."
        return 0
    fi

    log "ERROR: Remote SSH shutdown failed (exit code ${rc})."
    return 1
}

cmd_wake() {
    validate_ip

    # Fast-path: Ollama is already reachable
    if port_open "${ARCH_IP}" "${ARCH_OLLAMA_PORT}"; then
        log "Arch Linux and Ollama are already online (${ARCH_IP}:${ARCH_OLLAMA_PORT})."
        return 0
    fi

    # Dual-boot pre-check if the host already replies to ICMP ping before WoL
    if ping_host; then
        log "Host ${ARCH_IP} is already reachable via ICMP but Ollama is closed. Checking Dual-Boot (${DUALBOOT_GRACE_SEC}s grace)..."
        local pre_elapsed=0
        while [ "${pre_elapsed}" -lt "${DUALBOOT_GRACE_SEC}" ]; do
            if port_open "${ARCH_IP}" "${ARCH_OLLAMA_PORT}"; then
                log "Arch Linux + Ollama ready (${ARCH_IP}:${ARCH_OLLAMA_PORT})."
                return 0
            fi
            if port_open "${ARCH_IP}" "${ARCH_SSH_PORT}"; then
                log "SSH (${ARCH_SSH_PORT}) is open: Arch Linux is booted, waiting for Ollama..."
                break
            fi
            sleep "${POLL_INTERVAL_SEC}"
            pre_elapsed=$((pre_elapsed + POLL_INTERVAL_SEC))
        done

        if ! port_open "${ARCH_IP}" "${ARCH_SSH_PORT}" && ! port_open "${ARCH_IP}" "${ARCH_OLLAMA_PORT}"; then
            log "WARNING: ${ARCH_IP} replies to ping, but SSH (${ARCH_SSH_PORT}) and Ollama (${ARCH_OLLAMA_PORT}) ports remain closed."
            log "Dual-Boot detection: Windows 11 (or another OS) appears to be active. Exiting cleanly without blocking."
            return 2
        fi
    else
        send_wol_packet
    fi

    log "Waiting for Arch Linux workstation (${ARCH_IP}, timeout ${WOL_TIMEOUT_SEC}s)..."
    local elapsed=0
    local ping_no_linux_elapsed=0

    while [ "${elapsed}" -lt "${WOL_TIMEOUT_SEC}" ]; do
        if port_open "${ARCH_IP}" "${ARCH_OLLAMA_PORT}"; then
            log "Success: Arch Linux and Ollama are ready (${ARCH_IP}:${ARCH_OLLAMA_PORT})."
            return 0
        fi

        if ping_host; then
            if port_open "${ARCH_IP}" "${ARCH_SSH_PORT}"; then
                ping_no_linux_elapsed=0
                log "Arch Linux reachable (SSH OK), waiting for Ollama service (${elapsed}s/${WOL_TIMEOUT_SEC}s)..."
            else
                ping_no_linux_elapsed=$((ping_no_linux_elapsed + POLL_INTERVAL_SEC))
                log "Ping OK, but SSH (${ARCH_SSH_PORT}) and Ollama (${ARCH_OLLAMA_PORT}) are closed (${ping_no_linux_elapsed}s/${DUALBOOT_GRACE_SEC}s)..."
                if [ "${ping_no_linux_elapsed}" -ge "${DUALBOOT_GRACE_SEC}" ]; then
                    log "WARNING: Host replies to ping without opening SSH or Ollama after ${DUALBOOT_GRACE_SEC}s."
                    log "Dual-Boot detection: Windows 11 is likely booted. Exiting immediately (code 2)."
                    return 2
                fi
            fi
        else
            ping_no_linux_elapsed=0
            log "Host offline, waiting for boot (${elapsed}s/${WOL_TIMEOUT_SEC}s)..."
        fi

        sleep "${POLL_INTERVAL_SEC}"
        elapsed=$((elapsed + POLL_INTERVAL_SEC))
    done

    log "ERROR: Timeout reached (${WOL_TIMEOUT_SEC}s). Arch Linux workstation did not start Ollama."
    return 1
}

cmd_status() {
    validate_ip

    if ! ping_host; then
        log "Status: OFFLINE (Host ${ARCH_IP} powered down or unreachable)"
        return 1
    fi

    if port_open "${ARCH_IP}" "${ARCH_OLLAMA_PORT}"; then
        log "Status: ONLINE (Arch Linux + Ollama ready on ${ARCH_IP}:${ARCH_OLLAMA_PORT})"
        return 0
    fi

    if port_open "${ARCH_IP}" "${ARCH_SSH_PORT}"; then
        log "Status: BOOTING / PARTIAL (Arch Linux SSH OK, Ollama unavailable on ${ARCH_OLLAMA_PORT})"
        return 1
    fi

    log "Status: OTHER_OS (Ping OK on ${ARCH_IP}, but SSH ${ARCH_SSH_PORT} and Ollama ${ARCH_OLLAMA_PORT} closed - likely Windows 11 Dual-Boot)"
    return 2
}

cmd_shutdown() {
    validate_ip

    log "Checking workstation state prior to shutdown..."
    if ! ping_host; then
        log "Host ${ARCH_IP} is already offline. Nothing to do."
        return 0
    fi

    if ! port_open "${ARCH_IP}" "${ARCH_SSH_PORT}" && ! port_open "${ARCH_IP}" "${ARCH_OLLAMA_PORT}"; then
        log "WARNING: ${ARCH_IP} replies to ping, but SSH (${ARCH_SSH_PORT}) and Ollama (${ARCH_OLLAMA_PORT}) are closed."
        log "Dual-Boot detection: Windows 11 appears to be active. Skipping SSH shutdown cleanly (code 2)."
        return 2
    fi

    if ! port_open "${ARCH_IP}" "${ARCH_SSH_PORT}"; then
        log "ERROR: SSH port (${ARCH_SSH_PORT}) is closed on ${ARCH_IP}. Cannot execute safe-wol-shutdown."
        return 1
    fi

    log "Triggering safe remote shutdown on ${ARCH_IP}..."
    ssh_run_safe_shutdown
}

case "${1:-}" in
    wake|wakeup)
        cmd_wake
        ;;
    status)
        cmd_status
        ;;
    shutdown)
        cmd_shutdown
        ;;
    *)
        echo "Usage: $0 {wake|wakeup|status|shutdown}" >&2
        exit 1
        ;;
esac
