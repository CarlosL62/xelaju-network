#!/usr/bin/env bash
# Script auxiliar para consultar y generar metricas de trafico WAN para Zabbix

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${SCRIPT_DIR}/../config"
ENV_FILE="${CONFIG_DIR}/multiwan.env"

# leyendo las variables del env
if [[ -f "${ENV_FILE}" ]]; then
    # shellcheck source=/dev/null
    source "${ENV_FILE}"
fi

WAN1_IFACE="${WAN1_IFACE:-wlp3s0}"
WAN2_IFACE="${WAN2_IFACE:-wlxc006c3bf886a}"
ZABBIX_SERVER_IP="192.168.30.10"

ZABBIX_CONF_OUT="${CONFIG_DIR}/zabbix_multiwan.conf"

# metodo que muestra en consola los bytes y paquetes actuales de cada interfaz leyendo /sys/class/net
print_metrics() {
    echo "--- Metricas de Trafico Multi-WAN (kernel /sys/class/net) ---"
    
    echo "ISP 1 (${WAN1_IFACE}):"
    if [[ -d "/sys/class/net/${WAN1_IFACE}/statistics" ]]; then
        RX_B=$(cat "/sys/class/net/${WAN1_IFACE}/statistics/rx_bytes")
        TX_B=$(cat "/sys/class/net/${WAN1_IFACE}/statistics/tx_bytes")
        RX_P=$(cat "/sys/class/net/${WAN1_IFACE}/statistics/rx_packets")
        TX_P=$(cat "/sys/class/net/${WAN1_IFACE}/statistics/tx_packets")
        echo "  - Inbound (Entrada) : ${RX_B} bytes (${RX_P} paquetes)"
        echo "  - Outbound (Salida) : ${TX_B} bytes (${TX_P} paquetes)"
    else
        echo "  - Interfaz ${WAN1_IFACE} no presente o inactiva."
    fi

    echo "ISP 2 (${WAN2_IFACE}):"
    if [[ -d "/sys/class/net/${WAN2_IFACE}/statistics" ]]; then
        RX_B=$(cat "/sys/class/net/${WAN2_IFACE}/statistics/rx_bytes")
        TX_B=$(cat "/sys/class/net/${WAN2_IFACE}/statistics/tx_bytes")
        RX_P=$(cat "/sys/class/net/${WAN2_IFACE}/statistics/rx_packets")
        TX_P=$(cat "/sys/class/net/${WAN2_IFACE}/statistics/tx_packets")
        echo "  - Inbound (Entrada) : ${RX_B} bytes (${RX_P} paquetes)"
        echo "  - Outbound (Salida) : ${TX_B} bytes (${TX_P} paquetes)"
    else
        echo "  - Interfaz ${WAN2_IFACE} no presente o inactiva."
    fi
}

# generando el archivo zabbix_multiwan.conf con las interfaces y la IP del servidor de E1
generate_zabbix_config() {
    cat << EOF > "${ZABBIX_CONF_OUT}"
# Configuracion para que el agente de Zabbix reporte las metricas de E3 al servidor en E1
Server=${ZABBIX_SERVER_IP}
ServerActive=${ZABBIX_SERVER_IP}
Hostname=Router-MultiWAN-E3

# Metricas del enlace principal ISP1 leidas directamente desde el kernel
UserParameter=multiwan.isp1.rx_bytes,cat /sys/class/net/${WAN1_IFACE}/statistics/rx_bytes 2>/dev/null || echo 0
UserParameter=multiwan.isp1.tx_bytes,cat /sys/class/net/${WAN1_IFACE}/statistics/tx_bytes 2>/dev/null || echo 0
UserParameter=multiwan.isp1.rx_packets,cat /sys/class/net/${WAN1_IFACE}/statistics/rx_packets 2>/dev/null || echo 0
UserParameter=multiwan.isp1.tx_packets,cat /sys/class/net/${WAN1_IFACE}/statistics/tx_packets 2>/dev/null || echo 0

# Metricas del enlace secundario ISP2
UserParameter=multiwan.isp2.rx_bytes,cat /sys/class/net/${WAN2_IFACE}/statistics/rx_bytes 2>/dev/null || echo 0
UserParameter=multiwan.isp2.tx_bytes,cat /sys/class/net/${WAN2_IFACE}/statistics/tx_bytes 2>/dev/null || echo 0
UserParameter=multiwan.isp2.rx_packets,cat /sys/class/net/${WAN2_IFACE}/statistics/rx_packets 2>/dev/null || echo 0
UserParameter=multiwan.isp2.tx_packets,cat /sys/class/net/${WAN2_IFACE}/statistics/tx_packets 2>/dev/null || echo 0
EOF

    echo "[INFO] Archivo de configuracion para Zabbix generado en: ${ZABBIX_CONF_OUT}"
}

case "$1" in
    --generate)
        generate_zabbix_config
        ;;
    --print|--test)
        print_metrics
        ;;
    *)
        generate_zabbix_config
        echo ""
        print_metrics
        echo ""
        echo "Uso: $0 [--generate | --print]"
        ;;
esac
