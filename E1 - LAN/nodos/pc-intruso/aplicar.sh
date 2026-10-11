#!/bin/bash
# =============================================================================
# nodos/pc-intruso/aplicar.sh - configura (o restaura) PC-INTRUSO
# Equipo NO registrado conectado a la VLAN 20: demuestra el rechazo del DHCP y de las ACL.
# Uso, dentro de la VM:   sudo /mnt/proyecto/nodos/pc-intruso/aplicar.sh
# =============================================================================
set -euo pipefail

NODO=pc-intruso
AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
XJ_REPO="$(cd "$AQUI/../.." && pwd)"
. "$XJ_REPO/nodos/_comun/comun.sh"

xj_cliente "$NODO" "$AQUI"
xj_fin "PC-INTRUSO sin direccion. Pruebas: sudo /mnt/proyecto/pruebas/probar.sh intruso"
