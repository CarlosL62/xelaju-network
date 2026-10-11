#!/bin/bash
# =============================================================================
# nodos/pc-user02/aplicar.sh - configura (o restaura) PC-USER02
# Equipo de usuario: VLAN 20, IP por DHCP con reserva (192.168.20.11).
# Uso, dentro de la VM:   sudo /mnt/proyecto/nodos/pc-user02/aplicar.sh
# =============================================================================
set -euo pipefail

NODO=pc-user02
AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
XJ_REPO="$(cd "$AQUI/../.." && pwd)"
. "$XJ_REPO/nodos/_comun/comun.sh"

xj_cliente "$NODO" "$AQUI"
if ip -4 -o addr show dev lan0 | grep -q ' 192.168.20.11/'; then
    xj_ok "DHCP: recibio 192.168.20.11 (la IP reservada para su MAC)"
else
    xj_aviso "lan0 no tiene 192.168.20.11: revisa en R1-LAN 'xelaju-dhcp verificar' y el puerto del switch"
fi
xj_fin "PC-USER02: revisa que lan0 tenga 192.168.20.11 (reserva DHCP por MAC)"
