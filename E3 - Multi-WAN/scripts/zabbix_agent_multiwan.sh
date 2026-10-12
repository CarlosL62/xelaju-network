#!/usr/bin/env bash
# ==============================================================================
# XelajuNetwork - Estudiante 3: Multi-WAN, Balanceo y Failover
# Script de integracion de metricas de trafico WAN con Zabbix (Estudiante 1)
# ==============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${SCRIPT_DIR}/../config"
ENV_FILE="${CONFIG_DIR}/multiwan.env"

if [[ -f "${ENV_FILE}" ]]; then
    # shellcheck source=/dev/null
    source "${ENV_FILE}"
fi

WAN1_IFACE="${WAN1_IFACE:-wlp3s0}"
WAN2_IFACE="${WAN2_IFACE:-usb0}"
ZABBIX_SERVER_IP="192.168.30.10"

ZABBIX_CONF_OUT="${CONFIG_DIR}/zabbix_multiwan.conf"

print_metrics() {
    echo "=============================================================================="
    echo "    Metricas de Trafico Multi-WAN (Lectura en tiempo real de /sys/class/net) "
    echo "=============================================================================="
    
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
        echo "  - Interfaz ${WAN2_IFACE} no presente o inactiva (se activara al conectar Android)."
    fi
    echo "=============================================================================="
}

generate_zabbix_config() {
    cat << EOF > "${ZABBIX_CONF_OUT}"
# ==============================================================================
# XelajuNetwork - Zabbix Agent UserParameter para Multi-WAN (Estudiante 3)
# Servidor Zabbix destino: ${ZABBIX_SERVER_IP} (VLAN 30 - Servidores)
# ==============================================================================

Server=${ZABBIX_SERVER_IP}
ServerActive=${ZABBIX_SERVER_IP}
Hostname=Router-MultiWAN-E3

# Metricas ISP 1 (${WAN1_IFACE})
UserParameter=multiwan.isp1.rx_bytes,cat /sys/class/net/${WAN1_IFACE}/statistics/rx_bytes 2>/dev/null || echo 0
UserParameter=multiwan.isp1.tx_bytes,cat /sys/class/net/${WAN1_IFACE}/statistics/tx_bytes 2>/dev/null || echo 0
UserParameter=multiwan.isp1.rx_packets,cat /sys/class/net/${WAN1_IFACE}/statistics/rx_packets 2>/dev/null || echo 0
UserParameter=multiwan.isp1.tx_packets,cat /sys/class/net/${WAN1_IFACE}/statistics/tx_packets 2>/dev/null || echo 0

# Metricas ISP 2 (${WAN2_IFACE})
UserParameter=multiwan.isp2.rx_bytes,cat /sys/class/net/${WAN2_IFACE}/statistics/rx_bytes 2>/dev/null || echo 0
UserParameter=multiwan.isp2.tx_bytes,cat /sys/class/net/${WAN2_IFACE}/statistics/tx_bytes 2>/dev/null || echo 0
UserParameter=multiwan.isp2.rx_packets,cat /sys/class/net/${WAN2_IFACE}/statistics/rx_packets 2>/dev/null || echo 0
UserParameter=multiwan.isp2.tx_packets,cat /sys/class/net/${WAN2_IFACE}/statistics/tx_packets 2>/dev/null || echo 0
EOF

    echo "[INFO] Archivo de configuracion para Zabbix generado en: ${ZABBIX_CONF_OUT}"
    echo "Para activarlo en el sistema cuando Zabbix este listo:"
    echo "  sudo cp \"${ZABBIX_CONF_OUT}\" /etc/zabbix/zabbix_agentd.d/multiwan.conf"
    echo "  sudo systemctl restart zabbix-agent"
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
