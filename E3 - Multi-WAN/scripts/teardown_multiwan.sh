#!/usr/bin/env bash
# Script para limpiar y desmontar todas las reglas de Multi-WAN en e3

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${SCRIPT_DIR}/../config"
ENV_FILE="${CONFIG_DIR}/multiwan.env"

# leyendo las variables si existe el archivo env
if [[ -f "${ENV_FILE}" ]]; then
    # shellcheck source=/dev/null
    source "${ENV_FILE}"
fi

TABLE_ISP1="${TABLE_ISP1:-100}"
TABLE_ISP2="${TABLE_ISP2:-200}"
FWMARK_ISP1="${FWMARK_ISP1:-0x100}"
FWMARK_ISP2="${FWMARK_ISP2:-0x200}"

# verficando permisos de root para desarmar rutas y tablas
if [[ $EUID -ne 0 ]]; then
   echo "[ERROR] Este script debe ejecutarse con sudo." >&2
   exit 1
fi

echo "Limpiando configuracion de Multi-WAN..."

# eliminando las reglas de ip rule asociadas a las marcas
while ip rule del fwmark "${FWMARK_ISP1}" 2>/dev/null; do :; done
while ip rule del fwmark "${FWMARK_ISP2}" 2>/dev/null; do :; done

# vaciando las tablas de enrutamiento 100 y 200
ip route flush table "${TABLE_ISP1}" 2>/dev/null || true
ip route flush table "${TABLE_ISP2}" 2>/dev/null || true

# borrandola tabla de nftables para quitar marcas y NAT
nft delete table inet xelaju_multiwan 2>/dev/null || true

# quitando las rutas hacia las subredes internas
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

# si se levanto una interfaz virtual veth se elimina
if ip link show "${LAN_IFACE}" &>/dev/null && [[ "${LAN_IFACE}" == veth* ]]; then
    ip link del "${LAN_IFACE}" 2>/dev/null || true
fi

echo "[OK] Configuracion eliminada"
