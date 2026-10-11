#!/bin/bash
# =============================================================================
# nodos/pc-mgmt01/aplicar.sh - configura (o restaura) PC-MGMT01
# Estacion de gestion: VLAN 40, IP manual 192.168.40.10.
# Uso, dentro de la VM:   sudo /mnt/proyecto/nodos/pc-mgmt01/aplicar.sh
# =============================================================================
set -euo pipefail

NODO=pc-mgmt01
AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
XJ_REPO="$(cd "$AQUI/../.." && pwd)"
. "$XJ_REPO/nodos/_comun/comun.sh"

xj_cliente "$NODO" "$AQUI"
xj_fin "PC-MGMT01 (192.168.40.10)"
