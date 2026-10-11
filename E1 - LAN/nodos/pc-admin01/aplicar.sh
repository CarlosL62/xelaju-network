#!/bin/bash
# =============================================================================
# nodos/pc-admin01/aplicar.sh - configura (o restaura) PC-ADMIN01
# Equipo del administrador: VLAN 10, IP manual 192.168.10.50.
# Uso, dentro de la VM:   sudo /mnt/proyecto/nodos/pc-admin01/aplicar.sh
# =============================================================================
set -euo pipefail

NODO=pc-admin01
AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
XJ_REPO="$(cd "$AQUI/../.." && pwd)"
. "$XJ_REPO/nodos/_comun/comun.sh"

xj_cliente "$NODO" "$AQUI"
xj_fin "PC-ADMIN01 (192.168.10.50). Escritorio y navegador: sudo /mnt/proyecto/nodos/pc-admin01/escritorio.sh"
