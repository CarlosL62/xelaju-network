#!/bin/bash
# =============================================================================
# nodos/sw-core01/aplicar.sh - configura (o restaura) SW-CORE01
#
# Switch de nucleo: troncal a R1, troncal a SW-ACC01, puertos de acceso de
# servidores y gestion, y puerto espejo (SPAN).
# Uso, dentro de la VM:   sudo /mnt/proyecto/nodos/sw-core01/aplicar.sh
# =============================================================================
set -euo pipefail

NODO=sw-core01
AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
XJ_REPO="$(cd "$AQUI/../.." && pwd)"
. "$XJ_REPO/nodos/_comun/comun.sh"

xj_requerir_root
xj_base "$NODO"
xj_switch "$AQUI"

xj_paso "Agente de Zabbix (modo activo, autorregistro 'xelaju-lan')"
xj_agente_zabbix SW-CORE01 xelaju-lan

xj_fin "SW-CORE01. Ver estado: switch-mostrar vlan|trunk|mac|puertos|config"
