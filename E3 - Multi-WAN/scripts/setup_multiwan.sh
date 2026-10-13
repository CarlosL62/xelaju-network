#!/usr/bin/env bash
# Script principal para configurar tablas de rutas, nftables y reglas PBR en E3

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${SCRIPT_DIR}/../config"
ENV_FILE="${CONFIG_DIR}/multiwan.env"

# cargando las variables del .env si existe el archivo
if [[ -f "${ENV_FILE}" ]]; then
    # shellcheck source=/dev/null
    source "${ENV_FILE}"
else
    echo "[WARN] No encontre ${ENV_FILE}, usando valores por defecto."
fi

# Valores por defecto por si no se definieron en el .env
WAN1_IFACE="${WAN1_IFACE:-wlp3s0}"
WAN2_IFACE="${WAN2_IFACE:-wlxc006c3bf886a}"
LAN_IFACE="${LAN_IFACE:-eno1}"
LAN_IP="${LAN_IP:-192.168.81.1/30}"
E5_GATEWAY="${E5_GATEWAY:-192.168.81.2}"

# buscando si hay alguna antena wifi usb
if ! ip link show "${WAN2_IFACE}" &>/dev/null; then
    DETECTED_USB=$(ip -br link | awk '$1 ~ /^wlx/ {print $1}' | head -n1)
    if [[ -n "${DETECTED_USB}" ]]; then
        echo "[INFO] Auto-detecte antena WiFi USB activa: ${DETECTED_USB}"
        WAN2_IFACE="${DETECTED_USB}"
    fi
fi

# Tablas y marcas de enrutamiento
TABLE_ISP1="${TABLE_ISP1:-100}"
TABLE_ISP2="${TABLE_ISP2:-200}"
FWMARK_ISP1="${FWMARK_ISP1:-0x100}"
FWMARK_ISP2="${FWMARK_ISP2:-0x200}"

# Prioridades de ip rule para que queden antes de main
IP_RULE_PRIO_ISP1="${IP_RULE_PRIO_ISP1:-10100}"
IP_RULE_PRIO_ISP2="${IP_RULE_PRIO_ISP2:-10200}"

echo "--- Inicializando Router Multi-WAN (E3) ---"

# - Validando permisos de root para tocar rutas y nftables
if [[ $EUID -ne 0 ]]; then
   echo "[ERROR] Este script debe ejecutarse con sudo." >&2
   exit 1
fi

# - Activando el reenvio de paquetes y poniendo rp_filter en modo laxo para no botar paquetes asimetricos
echo "[1/7] Habilitando reenvio IPv4 y rp_filter laxo..."
sysctl -w net.ipv4.ip_forward=1 >/dev/null
sysctl -w net.ipv4.conf.all.rp_filter=2 >/dev/null
sysctl -w net.ipv4.conf.default.rp_filter=2 >/dev/null

if ip link show "${WAN1_IFACE}" &>/dev/null; then
    sysctl -w "net.ipv4.conf.${WAN1_IFACE}.rp_filter=2" >/dev/null
fi
if ip link show "${WAN2_IFACE}" &>/dev/null; then
    sysctl -w "net.ipv4.conf.${WAN2_IFACE}.rp_filter=2" >/dev/null
fi

# - buscando el gateway de cada proveedor para armar las rutas default
# -> gw ISP1
echo "[2/7] Detectando gateways de los proveedores..."
WAN1_GW=$(ip route show dev "${WAN1_IFACE}" 2>/dev/null | grep default | awk '{print $3}' | head -n1)
if [[ -z "${WAN1_GW}" ]]; then
    WAN1_IP=$(ip -4 addr show dev "${WAN1_IFACE}" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1)
    if [[ -n "${WAN1_IP}" ]]; then
        WAN1_GW="$(echo "${WAN1_IP}" | cut -d. -f1-3).1"
    fi
fi

# -> gw ISP2
WAN2_GW=$(ip route show dev "${WAN2_IFACE}" 2>/dev/null | grep default | awk '{print $3}' | head -n1)
if [[ -z "${WAN2_GW}" ]]; then
    WAN2_IP=$(ip -4 addr show dev "${WAN2_IFACE}" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1)
    if [[ -n "${WAN2_IP}" ]]; then
        WAN2_GW="$(echo "${WAN2_IP}" | cut -d. -f1-3).1"
    fi
fi

echo "  -> ISP1 (${WAN1_IFACE}): Gateway=${WAN1_GW:-No detectado aun}"
echo "  -> ISP2 (${WAN2_IFACE}): Gateway=${WAN2_GW:-No detectado aun}"

# verificando que la interfaz hacia E5 tenga su IP configurada
if ip link show "${LAN_IFACE}" &>/dev/null; then
    echo "[INFO] Verificando IP ${LAN_IP} en interfaz LAN ${LAN_IFACE}..."
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
fi

# - configurando las tablas 100 y 200 con su default gateway y ruta local conectada
echo "[3/7] Configurando tablas de rutas ${TABLE_ISP1} (ISP1) y ${TABLE_ISP2} (ISP2)..."
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

# - Creando las reglas de ip rule para que los paquetes marcados busquen su tabla asignada
echo "[4/7] Configurando reglas de enrutamiento ip rule..."
# borrando reglas previas para que el script sea idempotente y no duplique nada
while ip rule del fwmark "${FWMARK_ISP1}" 2>/dev/null; do :; done
while ip rule del fwmark "${FWMARK_ISP2}" 2>/dev/null; do :; done

ip rule add fwmark "${FWMARK_ISP1}" table "${TABLE_ISP1}" pref "${IP_RULE_PRIO_ISP1}"
ip rule add fwmark "${FWMARK_ISP2}" table "${TABLE_ISP2}" pref "${IP_RULE_PRIO_ISP2}"

# configurando la estructura de nftables: marcado de paquetes, balanceo y NAT
echo "[5/7] Configurando nftables (marcado PBR, balanceo y NAT)..."
if [[ "${WAN2_IFACE}" == wlx* ]]; then
    WAN2_NFT_MATCH="\"wlx*\""
else
    WAN2_NFT_MATCH="\"${WAN2_IFACE}\""
fi

# definiendo la tabla de nftables para PBR y NAT
cat << EOF | nft -f -
table inet xelaju_multiwan {
    chain pbr_mangle {
    }

    # ccadena para balancear 50 50 el trafico que no tenga politica especifica
    chain balance_fallback {
        meta mark 0 numgen random mod 2 0 meta mark set 0x100 counter comment "balance_50_isp1"
        meta mark 0 numgen random mod 2 1 meta mark set 0x200 counter comment "balance_50_isp2"
    }

    chain prerouting_mangle {
        type filter hook prerouting priority mangle; policy accept;

        # si el paquete viene de LAN y ya pertenece a una conexion previa se recupera su marca desde conntrack
        iifname "${LAN_IFACE}" meta mark set ct mark
        
        #si el paquete viene de lan y ya tiene una marca !=0 se acepta
        iifname "${LAN_IFACE}" meta mark != 0 accept

        # conexiones que entran por las WAN:
        # se guarda la marca en conntrack para que el trafico de vuelta salga por la misma interfaz WAN
        iifname "${WAN1_IFACE}" ct mark set 0x100 accept
        iifname ${WAN2_NFT_MATCH} ct mark set 0x200 accept

        # se evalua las politicas del txt para el trafico saliente
        iifname "${LAN_IFACE}" jump pbr_mangle

        # si es una conexion nueva sin politica se aplica el balanceo 50 50
        iifname "${LAN_IFACE}" meta mark 0 jump balance_fallback

        # se guarda la marca asignada en la sesion de conntrack para que los proximos paquetes no cambien de ruta
        iifname "${LAN_IFACE}" ct mark set meta mark
    }

    chain prerouting_nat {
        type nat hook prerouting priority dstnat; policy accept;
        # redireccion del puerto UDP 51820 para que las conexiones VPN lleguen a e4
        ip protocol udp udp dport 51820 dnat ip to 192.168.83.2:51820 comment "DNAT_WIREGUARD_E4"
    }

    chain postrouting_nat {
        type nat hook postrouting priority srcnat; policy accept;
    }
}
EOF

# Reglas de masquerade para salir a internet
if ip link show "${WAN1_IFACE}" &>/dev/null; then
    nft add rule inet xelaju_multiwan postrouting_nat oifname "${WAN1_IFACE}" masquerade
fi

if [[ "${WAN2_IFACE}" == wlx* ]]; then
    nft add rule inet xelaju_multiwan postrouting_nat oifname "wlx*" masquerade
elif ip link show "${WAN2_IFACE}" &>/dev/null; then
    nft add rule inet xelaju_multiwan postrouting_nat oifname "${WAN2_IFACE}" masquerade
fi

# 7- definiendo rutas de retorno hacia todas las subredes internas
echo "[6/7] Agregando rutas de retorno hacia redes internas (via ${E5_GATEWAY})..."
if ip link show "${LAN_IFACE}" &>/dev/null; then
    for tbl in "main" "${TABLE_ISP1}" "${TABLE_ISP2}"; do
        # ennlace con e5
        ip route replace 192.168.81.0/30 dev "${LAN_IFACE}" table "${tbl}" || true
        # subredes LAN de usuarios y administracion de e1
        ip route replace 192.168.10.0/24 via "${E5_GATEWAY}" dev "${LAN_IFACE}" onlink table "${tbl}" || true
        ip route replace 192.168.20.0/24 via "${E5_GATEWAY}" dev "${LAN_IFACE}" onlink table "${tbl}" || true
        ip route replace 192.168.30.0/24 via "${E5_GATEWAY}" dev "${LAN_IFACE}" onlink table "${tbl}" || true
        ip route replace 192.168.40.0/24 via "${E5_GATEWAY}" dev "${LAN_IFACE}" onlink table "${tbl}" || true
        # enlaces de transito entre "routers"
        ip route replace 192.168.82.0/30 via "${E5_GATEWAY}" dev "${LAN_IFACE}" onlink table "${tbl}" || true
        ip route replace 192.168.83.0/30 via "${E5_GATEWAY}" dev "${LAN_IFACE}" onlink table "${tbl}" || true
        ip route replace 192.168.84.0/30 via "${E5_GATEWAY}" dev "${LAN_IFACE}" onlink table "${tbl}" || true
        # redes de wireguard VPN y DMZ de e4
        ip route replace 10.200.10.0/24 via "${E5_GATEWAY}" dev "${LAN_IFACE}" onlink table "${tbl}" || true
        ip route replace 10.200.20.0/24 via "${E5_GATEWAY}" dev "${LAN_IFACE}" onlink table "${tbl}" || true
        ip route replace 172.16.10.0/24 via "${E5_GATEWAY}" dev "${LAN_IFACE}" onlink table "${tbl}" || true
    done
fi

# - ejecuntando el programa python para cargar las reglas de policies.txt
echo "[7/7] Aplicando politicas desde policies.txt..."
python3 "${SCRIPT_DIR}/apply_policies.py" --config "${POLICIES_FILE}"

echo "[OK] Router e3 configurado"
