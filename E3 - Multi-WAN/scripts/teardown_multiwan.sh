#!/usr/bin/env bash
# ==============================================================================
# XelajuNetwork - Estudiante 3: Multi-WAN, Balanceo y Failover
# Script de desmontaje limpio e idempotente de reglas de Multi-WAN
# ==============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${SCRIPT_DIR}/../config"
ENV_FILE="${CONFIG_DIR}/multiwan.env"

if [[ -f "${ENV_FILE}" ]]; then
    # shellcheck source=/dev/null
    source "${ENV_FILE}"
fi

TABLE_ISP1="${TABLE_ISP1:-100}"
TABLE_ISP2="${TABLE_ISP2:-200}"
FWMARK_ISP1="${FWMARK_ISP1:-0x100}"
FWMARK_ISP2="${FWMARK_ISP2:-0x200}"

if [[ $EUID -ne 0 ]]; then
   echo "[ERROR] Este script debe ejecutarse con privilegios de root (sudo)." >&2
   exit 1
fi

echo "Desmontando configuracion de Multi-WAN..."

# 1. Eliminar reglas ip rule
while ip rule del fwmark "${FWMARK_ISP1}" 2>/dev/null; do :; done
while ip rule del fwmark "${FWMARK_ISP2}" 2>/dev/null; do :; done

# 2. Limpiar tablas de enrutamiento 100 y 200
ip route flush table "${TABLE_ISP1}" 2>/dev/null || true
ip route flush table "${TABLE_ISP2}" 2>/dev/null || true

# 3. Eliminar tabla nftables
nft delete table inet xelaju_multiwan 2>/dev/null || true

# 4. Eliminar rutas internas (segun ADR-0002)
ip route del 192.168.10.0/24 2>/dev/null || true
ip route del 192.168.20.0/24 2>/dev/null || true
ip route del 192.168.30.0/24 2>/dev/null || true
ip route del 192.168.40.0/24 2>/dev/null || true
ip route del 192.168.82.0/30 2>/dev/null || true
ip route del 192.168.83.0/30 2>/dev/null || true
ip route del 192.168.84.0/30 2>/dev/null || true
ip route del 10.200.10.0/24 2>/dev/null || true
ip route del 10.200.20.0/24 2>/dev/null || true
ip route del 172.16.10.0/24 2>/dev/null || true

# 5. Eliminar interfaz veth si fue creada para pruebas
if ip link show "${LAN_IFACE}" &>/dev/null && [[ "${LAN_IFACE}" == veth* ]]; then
    ip link del "${LAN_IFACE}" 2>/dev/null || true
fi

echo "[EXITO] Configuracion de Multi-WAN desmontada limpiamente."
