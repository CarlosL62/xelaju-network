#!/usr/bin/env bash
# ==============================================================================
# setup_ids.sh - Configuración de Suricata IDS en E5
# ==============================================================================

set -euo pipefail

echo "======================================================================"
echo "    CONFIGURACIÓN DE SURICATA IDS (E5)"
echo "======================================================================"

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: Este script debe ejecutarse como root (sudo)."
    exit 1
fi

SURICATA_CONF="/etc/suricata/suricata.yaml"
if [ ! -f "$SURICATA_CONF" ]; then
    echo "ERROR: Archivo de configuración $SURICATA_CONF no encontrado."
    exit 1
fi

echo "[1] Configurando HOME_NET..."
NEW_HOME_NET="[192.168.10.0/24,192.168.20.0/24,192.168.30.0/24,192.168.40.0/24,10.200.10.0/24,10.200.20.0/24,172.16.10.0/24,192.168.81.0/30,192.168.82.0/30,192.168.83.0/30,192.168.84.0/30]"
sed -i "s|^    HOME_NET: \".*\"|    HOME_NET: \"$NEW_HOME_NET\"|" "$SURICATA_CONF"

echo "[2] Configurando explícitamente AF_PACKET..."
# Reemplazamos todo el bloque af-packet: de forma limpia y determinista
sed -i '/^af-packet:/,/^af-xdp:/c\
af-packet:\
  - interface: eno2\
    cluster-id: 99\
    cluster-type: cluster_flow\
    defrag: yes\
  - interface: enxc0eac367f731\
    cluster-id: 98\
    cluster-type: cluster_flow\
    defrag: yes\
  - interface: enxf8e43ba69459\
    cluster-id: 97\
    cluster-type: cluster_flow\
    defrag: yes\
\
af-xdp:' "$SURICATA_CONF"

# Comprobación de que no queda eth0 en af-packet y que las 3 existen
AF_PACKET_CONTENT=$(awk '/^af-packet:/{flag=1} /^[a-zA-Z0-9_-]+:/{if($1 != "af-packet:") flag=0} flag' "$SURICATA_CONF")
if echo "$AF_PACKET_CONTENT" | grep -q "interface: eth0"; then
    echo "ERROR: eth0 permanece configurada en af-packet."
    exit 1
fi
for iface in eno2 enxc0eac367f731 enxf8e43ba69459; do
    if ! echo "$AF_PACKET_CONTENT" | grep -q "interface: $iface"; then
        echo "ERROR: Interfaz $iface no encontrada en af-packet."
        exit 1
    fi
done
echo "    Verificación interna: AF_PACKET validado."

echo "[3] Garantizando activación de logs (eve.json y fast.log)..."
sed -i '/^  - fast:/,/^      append:/ s/enabled: no/enabled: yes/' "$SURICATA_CONF"
sed -i '/^  - eve-log:/,/^      filename:/ s/enabled: no/enabled: yes/' "$SURICATA_CONF"

echo "[4] Desplegando reglas personalizadas (local.rules)..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
LOCAL_RULES="${SCRIPT_DIR}/../../config/local.rules"
if [ -f "$LOCAL_RULES" ]; then
    mkdir -p /etc/suricata/rules
    cp "$LOCAL_RULES" /etc/suricata/rules/local.rules

    # Asegurar que rule-files contenga la ruta absoluta
    if ! grep -q "/etc/suricata/rules/local.rules" "$SURICATA_CONF"; then
        sed -i '/rule-files:/a \  - /etc/suricata/rules/local.rules' "$SURICATA_CONF"
    fi
    echo "    local.rules copiadas y configuradas en rule-files."
else
    echo "    ERROR: No se encontró $LOCAL_RULES."
    exit 1
fi

echo "======================================================================"
echo "    setup_ids.sh completó la manipulación de archivos correctamente."
echo "======================================================================"
