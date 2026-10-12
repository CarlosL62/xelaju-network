#!/usr/bin/env bash
# ==============================================================================
# XelajuNetwork - Estudiante 3: Multi-WAN, Balanceo y Failover
# Script de configuracion e inicializacion del Router Multi-WAN (Debian)
# Idempotente y configurable mediante variables de entorno.
# ==============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${SCRIPT_DIR}/../config"
ENV_FILE="${CONFIG_DIR}/multiwan.env"

if [[ -f "${ENV_FILE}" ]]; then
    # shellcheck source=/dev/null
    source "${ENV_FILE}"
else
    echo "[WARN] No se encontro ${ENV_FILE}, usando valores por defecto."
fi

# Valores por defecto si no vienen en .env
WAN1_IFACE="${WAN1_IFACE:-wlp3s0}"
WAN2_IFACE="${WAN2_IFACE:-usb0}"
LAN_IFACE="${LAN_IFACE:-veth-e3-e5}"
LAN_IP="${LAN_IP:-192.168.81.1/30}"
E5_GATEWAY="${E5_GATEWAY:-192.168.81.2}"

# Auto-deteccion de interfaz USB si no existe la configurada
if ! ip link show "${WAN2_IFACE}" &>/dev/null; then
    DETECTED_USB=$(ip -br link | awk '$1 ~ /^(usb|enx|wlx)/ {print $1}' | head -n1)
    if [[ -n "${DETECTED_USB}" ]]; then
        echo "[INFO] Auto-detectada interfaz USB activa: ${DETECTED_USB}"
        WAN2_IFACE="${DETECTED_USB}"
    fi
fi

TABLE_ISP1="${TABLE_ISP1:-100}"
TABLE_ISP2="${TABLE_ISP2:-200}"
FWMARK_ISP1="${FWMARK_ISP1:-0x100}"
FWMARK_ISP2="${FWMARK_ISP2:-0x200}"

IP_RULE_PRIO_ISP1="${IP_RULE_PRIO_ISP1:-10100}"
IP_RULE_PRIO_ISP2="${IP_RULE_PRIO_ISP2:-10200}"

echo "=============================================================================="
echo "    XelajuNetwork - Inicializando Router Multi-WAN (Estudiante 3)             "
echo "=============================================================================="

# 1. Validar permisos de root
if [[ $EUID -ne 0 ]]; then
   echo "[ERROR] Este script debe ejecutarse con privilegios de root (sudo)." >&2
   exit 1
fi

# 2. Habilitar reenvio de paquetes IPv4 en el Kernel
echo "[1/7] Habilitando IPv4 forwarding y rp_filter laxo..."
sysctl -w net.ipv4.ip_forward=1 >/dev/null
sysctl -w net.ipv4.conf.all.rp_filter=2 >/dev/null
sysctl -w net.ipv4.conf.default.rp_filter=2 >/dev/null

if ip link show "${WAN1_IFACE}" &>/dev/null; then
    sysctl -w "net.ipv4.conf.${WAN1_IFACE}.rp_filter=2" >/dev/null
fi
if ip link show "${WAN2_IFACE}" &>/dev/null; then
    sysctl -w "net.ipv4.conf.${WAN2_IFACE}.rp_filter=2" >/dev/null
fi

# 3. Detectar Gateways de WAN1 y WAN2
echo "[2/7] Detectando o verificando gateways de los ISP..."
WAN1_GW=$(ip route show dev "${WAN1_IFACE}" 2>/dev/null | grep default | awk '{print $3}' | head -n1)
if [[ -z "${WAN1_GW}" ]]; then
    # Intenta obtener la primera IP de la red como fallback
    WAN1_IP=$(ip -4 addr show dev "${WAN1_IFACE}" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1)
    if [[ -n "${WAN1_IP}" ]]; then
        WAN1_GW="$(echo "${WAN1_IP}" | cut -d. -f1-3).1"
    fi
fi

WAN2_GW=$(ip route show dev "${WAN2_IFACE}" 2>/dev/null | grep default | awk '{print $3}' | head -n1)
if [[ -z "${WAN2_GW}" ]]; then
    WAN2_IP=$(ip -4 addr show dev "${WAN2_IFACE}" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1)
    if [[ -n "${WAN2_IP}" ]]; then
        WAN2_GW="$(echo "${WAN2_IP}" | cut -d. -f1-3).1"
    fi
fi

echo "  -> WAN1 (${WAN1_IFACE}): Gateway=${WAN1_GW:-No detectado aun}"
echo "  -> WAN2 (${WAN2_IFACE}): Gateway=${WAN2_GW:-No detectado aun}"

# Auto-configurar interfaz LAN (soporta interfaz fisica como eno1 o virtual veth)
if ip link show "${LAN_IFACE}" &>/dev/null; then
    echo "[INFO] Configurando interfaz LAN ${LAN_IFACE} con IP ${LAN_IP}..."
    if command -v nmcli &>/dev/null; then
        NM_CON=$(nmcli -t -f DEVICE,NAME con show --active 2>/dev/null | grep "^${LAN_IFACE}:" | cut -d: -f2- || true)
        if [[ -z "${NM_CON}" ]]; then
            NM_CON=$(nmcli -t -f DEVICE,NAME con show 2>/dev/null | grep "^${LAN_IFACE}:" | cut -d: -f2- || true)
        fi
        if [[ -n "${NM_CON}" ]]; then
            nmcli connection modify "${NM_CON}" ipv4.addresses "${LAN_IP}" ipv4.method manual 2>/dev/null || true
            nmcli connection up "${NM_CON}" 2>/dev/null || true
        fi
    fi
    ip link set "${LAN_IFACE}" up || true
    if ! ip -4 addr show dev "${LAN_IFACE}" | grep -q "${LAN_IP%/*}"; then
        ip addr add "${LAN_IP}" dev "${LAN_IFACE}" || true
    fi
elif [[ "${LAN_IFACE}" == veth* ]]; then
    echo "[INFO] Creando interfaz LAN virtual ${LAN_IFACE} con peer veth-client..."
    ip link add "${LAN_IFACE}" type veth peer name veth-client || true
    ip addr add "${LAN_IP}" dev "${LAN_IFACE}" || true
    ip link set "${LAN_IFACE}" up || true
    ip addr add "${E5_GATEWAY}/30" dev veth-client || true
    ip link set veth-client up || true
fi

# 4. Configurar Tablas de Enrutamiento para cada ISP
echo "[3/7] Configurando tablas de enrutamiento ${TABLE_ISP1} (ISP1) y ${TABLE_ISP2} (ISP2)..."
if [[ -n "${WAN1_GW}" ]]; then
    ip route flush table "${TABLE_ISP1}" || true
    ip route add default via "${WAN1_GW}" dev "${WAN1_IFACE}" table "${TABLE_ISP1}"
    WAN1_LINK=$(ip -4 route show dev "${WAN1_IFACE}" scope link 2>/dev/null | head -n1)
    if [[ -n "${WAN1_LINK}" ]]; then
        WAN1_NET=$(echo "${WAN1_LINK}" | awk '{print $1}')
        WAN1_SRC=$(echo "${WAN1_LINK}" | grep -oP '(?<=src\s)\S+')
        [[ -z "${WAN1_SRC}" ]] && WAN1_SRC=$(ip -4 addr show dev "${WAN1_IFACE}" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1)
        if [[ -n "${WAN1_NET}" && -n "${WAN1_SRC}" ]]; then
            ip route replace "${WAN1_NET}" dev "${WAN1_IFACE}" scope link src "${WAN1_SRC}" table "${TABLE_ISP1}" 2>/dev/null || true
        fi
    fi
    if ip link show "${LAN_IFACE}" &>/dev/null; then
        ip route add 192.168.81.0/30 dev "${LAN_IFACE}" table "${TABLE_ISP1}" || true
    fi
fi

if [[ -n "${WAN2_GW}" ]]; then
    ip route flush table "${TABLE_ISP2}" || true
    ip route add default via "${WAN2_GW}" dev "${WAN2_IFACE}" table "${TABLE_ISP2}"
    WAN2_LINK=$(ip -4 route show dev "${WAN2_IFACE}" scope link 2>/dev/null | head -n1)
    if [[ -n "${WAN2_LINK}" ]]; then
        WAN2_NET=$(echo "${WAN2_LINK}" | awk '{print $1}')
        WAN2_SRC=$(echo "${WAN2_LINK}" | grep -oP '(?<=src\s)\S+')
        [[ -z "${WAN2_SRC}" ]] && WAN2_SRC=$(ip -4 addr show dev "${WAN2_IFACE}" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1)
        if [[ -n "${WAN2_NET}" && -n "${WAN2_SRC}" ]]; then
            ip route replace "${WAN2_NET}" dev "${WAN2_IFACE}" scope link src "${WAN2_SRC}" table "${TABLE_ISP2}" 2>/dev/null || true
        fi
    fi
    if ip link show "${LAN_IFACE}" &>/dev/null; then
        ip route add 192.168.81.0/30 dev "${LAN_IFACE}" table "${TABLE_ISP2}" || true
    fi
fi

# 5. Configurar Reglas de Enrutamiento por Marca (ip rule)
echo "[4/7] Configurando reglas de enrutamiento ip rule..."
# Limpieza idempotente previa de nuestras reglas
while ip rule del fwmark "${FWMARK_ISP1}" 2>/dev/null; do :; done
while ip rule del fwmark "${FWMARK_ISP2}" 2>/dev/null; do :; done

ip rule add fwmark "${FWMARK_ISP1}" table "${TABLE_ISP1}" pref "${IP_RULE_PRIO_ISP1}"
ip rule add fwmark "${FWMARK_ISP2}" table "${TABLE_ISP2}" pref "${IP_RULE_PRIO_ISP2}"

# 6. Configurar nftables para NAT, Balanceo y Mangle con Connection Tracking (ct mark)
echo "[5/7] Configurando estructura nftables (NAT, PBR, y Balanceo con Connection Tracking)..."
if [[ "${WAN2_IFACE}" == enx* || "${WAN2_IFACE}" == usb* || "${WAN2_IFACE}" == wlx* ]]; then
    WAN2_NFT_MATCH="{ \"enx*\", \"usb*\", \"wlx*\" }"
else
    WAN2_NFT_MATCH="\"${WAN2_IFACE}\""
fi

cat << EOF | nft -f -
table inet xelaju_multiwan {
    chain pbr_mangle {
    }

    chain balance_fallback {
        meta mark 0 numgen random mod 2 0 meta mark set 0x100 counter comment "balance_50_isp1"
        meta mark 0 numgen random mod 2 1 meta mark set 0x200 counter comment "balance_50_isp2"
    }

    chain prerouting_mangle {
        type filter hook prerouting priority mangle; policy accept;

        # 1. Restaurar marca previa SOLO para paquetes que entran desde LAN (E5)
        # Las respuestas de hosts de Internet hacia clientes LAN no se re-marcan, viajando limpias por main
        iifname "${LAN_IFACE}" meta mark set ct mark
        iifname "${LAN_IFACE}" meta mark != 0 accept

        # 2. Conexiones entrantes por WAN (DNAT WireGuard hacia E4):
        # Marcar SOLO la conexion en conntrack (ct mark) para que las respuestas salgan por ese mismo ISP.
        # NO se aplica meta mark al paquete para que viaje limpio hacia E5 y E4 via tabla main.
        iifname "${WAN1_IFACE}" ct mark set 0x100 accept
        iifname ${WAN2_NFT_MATCH} ct mark set 0x200 accept

        # 3. Evaluar politicas de policies.txt (solo trafico saliente desde LAN)
        iifname "${LAN_IFACE}" jump pbr_mangle

        # 4. Balanceo 50/50 solo para conexiones nuevas desde LAN sin coincidencia en policies.txt
        iifname "${LAN_IFACE}" meta mark 0 jump balance_fallback

        # 5. Guardar la marca decidida en la conexion (paquete -> conntrack)
        iifname "${LAN_IFACE}" ct mark set meta mark
    }

    chain prerouting_nat {
        type nat hook prerouting priority dstnat; policy accept;
        # DNAT para WireGuard VPN entrante hacia E4 (192.168.83.2)
        ip protocol udp udp dport 51820 dnat ip to 192.168.83.2:51820 comment "DNAT_WIREGUARD_E4"
    }

    chain postrouting_nat {
        type nat hook postrouting priority srcnat; policy accept;
    }
}
EOF

# Aplicar reglas de masquerade segun las interfaces WAN activas
if ip link show "${WAN1_IFACE}" &>/dev/null; then
    nft add rule inet xelaju_multiwan postrouting_nat oifname "${WAN1_IFACE}" masquerade
fi
if [[ "${WAN2_IFACE}" == enx* || "${WAN2_IFACE}" == usb* || "${WAN2_IFACE}" == wlx* ]]; then
    nft add rule inet xelaju_multiwan postrouting_nat oifname { "enx*", "usb*", "wlx*" } masquerade
elif ip link show "${WAN2_IFACE}" &>/dev/null; then
    nft add rule inet xelaju_multiwan postrouting_nat oifname "${WAN2_IFACE}" masquerade
fi

# 7. Agregar rutas hacia las redes internas (detras de E5 192.168.81.2) - Segun ADR-0002
# Se agregan en tabla main y en tablas 100/200 para garantizar enrutamiento simetrico
echo "[6/7] Agregando rutas hacia redes internas de XelajuNetwork (via ${E5_GATEWAY})..."
if ip link show "${LAN_IFACE}" &>/dev/null; then
    for tbl in "main" "${TABLE_ISP1}" "${TABLE_ISP2}"; do
        # Asegurar subred del enlace local con E5
        ip route replace 192.168.81.0/30 dev "${LAN_IFACE}" table "${tbl}" || true
        # VLANs internas LAN (E1)
        ip route replace 192.168.10.0/24 via "${E5_GATEWAY}" dev "${LAN_IFACE}" onlink table "${tbl}" || true
        ip route replace 192.168.20.0/24 via "${E5_GATEWAY}" dev "${LAN_IFACE}" onlink table "${tbl}" || true
        ip route replace 192.168.30.0/24 via "${E5_GATEWAY}" dev "${LAN_IFACE}" onlink table "${tbl}" || true
        ip route replace 192.168.40.0/24 via "${E5_GATEWAY}" dev "${LAN_IFACE}" onlink table "${tbl}" || true
        # Enlaces de transito
        ip route replace 192.168.82.0/30 via "${E5_GATEWAY}" dev "${LAN_IFACE}" onlink table "${tbl}" || true
        ip route replace 192.168.83.0/30 via "${E5_GATEWAY}" dev "${LAN_IFACE}" onlink table "${tbl}" || true
        ip route replace 192.168.84.0/30 via "${E5_GATEWAY}" dev "${LAN_IFACE}" onlink table "${tbl}" || true
        # WireGuard VPN (E4)
        ip route replace 10.200.10.0/24 via "${E5_GATEWAY}" dev "${LAN_IFACE}" onlink table "${tbl}" || true
        ip route replace 10.200.20.0/24 via "${E5_GATEWAY}" dev "${LAN_IFACE}" onlink table "${tbl}" || true
        # DMZ (E4)
        ip route replace 172.16.10.0/24 via "${E5_GATEWAY}" dev "${LAN_IFACE}" onlink table "${tbl}" || true
    done
fi

# 8. Cargar y aplicar politicas externas desde policies.txt
echo "[7/7] Aplicando politicas de policies.txt..."
python3 "${SCRIPT_DIR}/apply_policies.py" --config "${POLICIES_FILE}"

echo "=============================================================================="
echo "    [EXITO] Router Multi-WAN configurado y activo.                           "
echo "=============================================================================="
