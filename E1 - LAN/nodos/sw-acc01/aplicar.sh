#!/bin/bash
# =============================================================================
# nodos/sw-acc01/aplicar.sh - configura (o restaura) SW-ACC01
#
# Switch de acceso: troncal a SW-CORE01 y puertos de acceso de los PC
# (VLAN 10 ADMIN y VLAN 20 USUARIOS).
# Uso, dentro de la VM:   sudo /mnt/proyecto/nodos/sw-acc01/aplicar.sh
# =============================================================================
set -euo pipefail

NODO=sw-acc01
AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
XJ_REPO="$(cd "$AQUI/../.." && pwd)"
. "$XJ_REPO/nodos/_comun/comun.sh"

xj_requerir_root
xj_base "$NODO"
xj_switch "$AQUI"

xj_paso "Agente de Zabbix (modo activo, autorregistro 'xelaju-lan')"
xj_agente_zabbix SW-ACC01 xelaju-lan

xj_fin "SW-ACC01. Ver estado: switch-mostrar vlan|trunk|mac|puertos|config"
