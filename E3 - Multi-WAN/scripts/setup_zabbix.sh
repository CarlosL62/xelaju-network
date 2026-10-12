#!/usr/bin/env bash
# Script para instalar y dejar corriendo el agente de Zabbix en E3

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${SCRIPT_DIR}/../config"
SRC_CONF="${CONFIG_DIR}/zabbix_multiwan.conf"
ZABBIX_MAIN_CONF="/etc/zabbix/zabbix_agentd.conf"
ZABBIX_DROPIN_DIR="/etc/zabbix/zabbix_agentd.conf.d"

# Ocupamos permisos de root para editar la configuracion de zabbix
if [[ $EUID -ne 0 ]]; then
    echo "[ERROR] Este script debe ejecutarse con sudo: sudo ./scripts/setup_zabbix.sh" >&2
    exit 1
fi

echo "[1/4] Generando configuracion de metricas para ISP1 e ISP2..."
"${SCRIPT_DIR}/zabbix_agent_multiwan.sh" --generate

echo "[2/4] Apuntando al servidor Zabbix de E1 en ${ZABBIX_MAIN_CONF}..."
sed -i 's/^Server=.*/Server=192.168.30.10/' "${ZABBIX_MAIN_CONF}"
sed -i 's/^ServerActive=.*/ServerActive=192.168.30.10/' "${ZABBIX_MAIN_CONF}"
if grep -q "^Hostname=" "${ZABBIX_MAIN_CONF}"; then
    sed -i 's/^Hostname=.*/Hostname=Router-MultiWAN-E3/' "${ZABBIX_MAIN_CONF}"
else
    sed -i 's/^# Hostname=/Hostname=Router-MultiWAN-E3/' "${ZABBIX_MAIN_CONF}"
fi

echo "[3/4] Copiando parametros UserParameter a ${ZABBIX_DROPIN_DIR}/multiwan.conf..."
mkdir -p "${ZABBIX_DROPIN_DIR}"
cp "${SRC_CONF}" "${ZABBIX_DROPIN_DIR}/multiwan.conf"

echo "[4/4] Habilitando y reiniciando el servicio zabbix-agent..."
systemctl enable --now zabbix-agent
systemctl restart zabbix-agent

echo ""
echo "--- Zabbix Agent configurado y corriendo correctamente ---"
echo "Probando metricas con /usr/sbin/zabbix_agentd:"
echo -n "  - ISP1 Bytes recibidos: "
/usr/sbin/zabbix_agentd -t multiwan.isp1.rx_bytes 2>/dev/null || echo "Error"
echo -n "  - ISP2 Bytes recibidos: "
/usr/sbin/zabbix_agentd -t multiwan.isp2.rx_bytes 2>/dev/null || echo "Error"
