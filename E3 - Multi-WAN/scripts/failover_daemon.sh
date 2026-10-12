#!/usr/bin/env bash
# ==============================================================================
# XelajuNetwork - Estudiante 3: Multi-WAN, Balanceo y Failover
# Demonio de Monitoreo, Failover y Recuperacion Automatica (Failback)
# Resiliente a cambio de MAC / reconexion USB de Android (enx*)
# ==============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${SCRIPT_DIR}/../config"
ENV_FILE="${CONFIG_DIR}/multiwan.env"

if [[ -f "${ENV_FILE}" ]]; then
    # shellcheck source=/dev/null
    source "${ENV_FILE}"
fi

WAN1_IFACE="${WAN1_IFACE:-wlp3s0}"
WAN2_IFACE="${WAN2_IFACE:-usb0}"

TABLE_ISP1="${TABLE_ISP1:-100}"
TABLE_ISP2="${TABLE_ISP2:-200}"
FWMARK_ISP1="${FWMARK_ISP1:-0x100}"
FWMARK_ISP2="${FWMARK_ISP2:-0x200}"
IP_RULE_PRIO_ISP1="${IP_RULE_PRIO_ISP1:-10100}"
IP_RULE_PRIO_ISP2="${IP_RULE_PRIO_ISP2:-10200}"

FAILOVER_INTERVAL_SEC="${FAILOVER_INTERVAL_SEC:-2}"
FAILOVER_TIMEOUT_SEC="${FAILOVER_TIMEOUT_SEC:-1}"
CHECK_TARGET_1="${CHECK_TARGET_1:-8.8.8.8}"
CHECK_TARGET_2="${CHECK_TARGET_2:-1.1.1.1}"

LOG_FILE="${LOG_FILE:-${SCRIPT_DIR}/../failover.log}"

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg"
    echo "$msg" >> "${LOG_FILE}"
}

cleanup() {
    log "[INFO] Deteniendo demonio de failover... Restaurando reglas por defecto."
    ip rule del fwmark "${FWMARK_ISP1}" table "${TABLE_ISP2}" pref "${IP_RULE_PRIO_ISP1}" 2>/dev/null || true
    ip rule del fwmark "${FWMARK_ISP2}" table "${TABLE_ISP1}" pref "${IP_RULE_PRIO_ISP2}" 2>/dev/null || true
    ip rule del fwmark "${FWMARK_ISP1}" table "${TABLE_ISP1}" pref "${IP_RULE_PRIO_ISP1}" 2>/dev/null || true
    ip rule del fwmark "${FWMARK_ISP2}" table "${TABLE_ISP2}" pref "${IP_RULE_PRIO_ISP2}" 2>/dev/null || true
    ip rule add fwmark "${FWMARK_ISP1}" table "${TABLE_ISP1}" pref "${IP_RULE_PRIO_ISP1}" 2>/dev/null || true
    ip rule add fwmark "${FWMARK_ISP2}" table "${TABLE_ISP2}" pref "${IP_RULE_PRIO_ISP2}" 2>/dev/null || true
    exit 0
}

trap cleanup SIGINT SIGTERM

detect_active_usb() {
    # Busca cualquier interfaz usb* o enx* que tenga direccion IP asignada y este UP
    local iface
    iface=$(ip -br addr | awk '$1 ~ /^(usb|enx|wlx)/ && $3 ~ /\./ {print $1}' | head -n1)
    if [[ -z "${iface}" ]]; then
        # Fallback a cualquier interfaz usb o enx en link UP
        iface=$(ip -br link | awk '$1 ~ /^(usb|enx|wlx)/ && $2 ~ /(UP|UNKNOWN)/ {print $1}' | head -n1)
    fi
    echo "${iface}"
}

ensure_table_route() {
    local iface="$1"
    local table="$2"
    local gw
    
    gw=$(ip route show dev "${iface}" 2>/dev/null | grep default | awk '{print $3}' | head -n1)
    if [[ -z "${gw}" ]]; then
        local ip_addr
        ip_addr=$(ip -4 addr show dev "${iface}" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1)
        if [[ -n "${ip_addr}" ]]; then
            gw="$(echo "${ip_addr}" | cut -d. -f1-3).1"
        fi
    fi

    if [[ -n "${gw}" ]]; then
        # Asegura la ruta default en la tabla correspondiente
        ip route replace default via "${gw}" dev "${iface}" table "${table}" 2>/dev/null || true
        # Asegura la ruta de la red conectada (link-scope) con su src
        local link_route
        link_route=$(ip -4 route show dev "${iface}" scope link 2>/dev/null | head -n1)
        if [[ -n "${link_route}" ]]; then
            local net_prefix src_ip
            net_prefix=$(echo "${link_route}" | awk '{print $1}')
            src_ip=$(echo "${link_route}" | grep -oP '(?<=src\s)\S+')
            [[ -z "${src_ip}" ]] && src_ip=$(ip -4 addr show dev "${iface}" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1)
            if [[ -n "${net_prefix}" && -n "${src_ip}" ]]; then
                ip route replace "${net_prefix}" dev "${iface}" scope link src "${src_ip}" table "${table}" 2>/dev/null || true
            fi
        fi
        # Asegura masquerade en nftables para la interfaz activa
        if ! nft list chain inet xelaju_multiwan postrouting_nat 2>/dev/null | grep -q "oifname \"${iface}\" masquerade"; then
            nft add rule inet xelaju_multiwan postrouting_nat oifname "${iface}" masquerade 2>/dev/null || true
        fi
    fi
}

ensure_internal_routes() {
    local lan_iface="${LAN_IFACE:-eno1}"
    local e5_gw="${E5_GATEWAY:-192.168.81.2}"
    if ip link show "${lan_iface}" &>/dev/null; then
        for tbl in "main" "${TABLE_ISP1}" "${TABLE_ISP2}"; do
            ip route replace 192.168.81.0/30 dev "${lan_iface}" table "${tbl}" 2>/dev/null || true
            ip route replace 192.168.10.0/24 via "${e5_gw}" dev "${lan_iface}" onlink table "${tbl}" 2>/dev/null || true
            ip route replace 192.168.20.0/24 via "${e5_gw}" dev "${lan_iface}" onlink table "${tbl}" 2>/dev/null || true
            ip route replace 192.168.30.0/24 via "${e5_gw}" dev "${lan_iface}" onlink table "${tbl}" 2>/dev/null || true
            ip route replace 192.168.40.0/24 via "${e5_gw}" dev "${lan_iface}" onlink table "${tbl}" 2>/dev/null || true
            ip route replace 192.168.82.0/30 via "${e5_gw}" dev "${lan_iface}" onlink table "${tbl}" 2>/dev/null || true
            ip route replace 192.168.83.0/30 via "${e5_gw}" dev "${lan_iface}" onlink table "${tbl}" 2>/dev/null || true
            ip route replace 192.168.84.0/30 via "${e5_gw}" dev "${lan_iface}" onlink table "${tbl}" 2>/dev/null || true
            ip route replace 10.200.10.0/24 via "${e5_gw}" dev "${lan_iface}" onlink table "${tbl}" 2>/dev/null || true
            ip route replace 10.200.20.0/24 via "${e5_gw}" dev "${lan_iface}" onlink table "${tbl}" 2>/dev/null || true
            ip route replace 172.16.10.0/24 via "${e5_gw}" dev "${lan_iface}" onlink table "${tbl}" 2>/dev/null || true
        done
    fi
}

check_link() {
    local iface="$1"
    if [[ -z "${iface}" ]] || ! ip link show "${iface}" 2>/dev/null | grep -q "UP"; then
        return 1
    fi

    # Ping a objetivo 1
    if ping -I "${iface}" -c 1 -W "${FAILOVER_TIMEOUT_SEC}" "${CHECK_TARGET_1}" >/dev/null 2>&1; then
        return 0
    fi
    # Ping a objetivo 2 de respaldo
    if ping -I "${iface}" -c 1 -W "${FAILOVER_TIMEOUT_SEC}" "${CHECK_TARGET_2}" >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

# Estados iniciales
ISP1_STATUS="UNKNOWN"
ISP2_STATUS="UNKNOWN"

log "=============================================================================="
log "[INICIO] Demonio de Failover Multi-WAN iniciado"
log "  Monitoreando ISP1 (${WAN1_IFACE}) y ISP2 (${WAN2_IFACE})"
log "  Intervalo de chequeo: ${FAILOVER_INTERVAL_SEC}s"
log "=============================================================================="

while true; do
    # Asegurar rutas hacia subredes internas detras de E5
    ensure_internal_routes

    # Chequear ISP1
    if check_link "${WAN1_IFACE}"; then
        CURRENT_ISP1="UP"
        ensure_table_route "${WAN1_IFACE}" "${TABLE_ISP1}"
    else
        CURRENT_ISP1="DOWN"
    fi

    # Auto-detectar interfaz USB de ISP2 (por si cambio de nombre/MAC al reconectar)
    DYNAMIC_USB=$(detect_active_usb)
    if [[ -n "${DYNAMIC_USB}" ]]; then
        WAN2_IFACE="${DYNAMIC_USB}"
    fi

    # Chequear ISP2
    if check_link "${WAN2_IFACE}"; then
        CURRENT_ISP2="UP"
        # Asegurar que la tabla 200 tenga su ruta tras reconexion USB
        ensure_table_route "${WAN2_IFACE}" "${TABLE_ISP2}"
    else
        CURRENT_ISP2="DOWN"
    fi

    # Manejar transicion de ISP1
    if [[ "${CURRENT_ISP1}" != "${ISP1_STATUS}" ]]; then
        if [[ "${CURRENT_ISP1}" == "DOWN" ]]; then
            log "[ALERTA] ISP1 (${WAN1_IFACE}) HA CAIDO! Ejecutando failover hacia ISP2 (Tabla ${TABLE_ISP2})..."
            ip rule del fwmark "${FWMARK_ISP1}" 2>/dev/null || true
            ip rule add fwmark "${FWMARK_ISP1}" table "${TABLE_ISP2}" pref "${IP_RULE_PRIO_ISP1}"
        else
            log "[RECUPERACION] ISP1 (${WAN1_IFACE}) ESTA DISPONIBLE NUEVAMENTE! Restaurando politica normal (Tabla ${TABLE_ISP1})..."
            ip rule del fwmark "${FWMARK_ISP1}" 2>/dev/null || true
            ip rule add fwmark "${FWMARK_ISP1}" table "${TABLE_ISP1}" pref "${IP_RULE_PRIO_ISP1}"
        fi
        ISP1_STATUS="${CURRENT_ISP1}"
    fi

    # Manejar transicion de ISP2
    if [[ "${CURRENT_ISP2}" != "${ISP2_STATUS}" ]]; then
        if [[ "${CURRENT_ISP2}" == "DOWN" ]]; then
            log "[ALERTA] ISP2 (${WAN2_IFACE}) HA CAIDO! Ejecutando failover hacia ISP1 (Tabla ${TABLE_ISP1})..."
            ip rule del fwmark "${FWMARK_ISP2}" 2>/dev/null || true
            ip rule add fwmark "${FWMARK_ISP2}" table "${TABLE_ISP1}" pref "${IP_RULE_PRIO_ISP2}"
        else
            log "[RECUPERACION] ISP2 (${WAN2_IFACE}) ESTA DISPONIBLE NUEVAMENTE! Restaurando politica normal (Tabla ${TABLE_ISP2})..."
            ip rule del fwmark "${FWMARK_ISP2}" 2>/dev/null || true
            ip rule add fwmark "${FWMARK_ISP2}" table "${TABLE_ISP2}" pref "${IP_RULE_PRIO_ISP2}"
        fi
        ISP2_STATUS="${CURRENT_ISP2}"
    fi

    sleep "${FAILOVER_INTERVAL_SEC}"
done
