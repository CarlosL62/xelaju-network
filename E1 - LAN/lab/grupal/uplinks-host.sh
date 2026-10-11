#!/bin/bash
# =============================================================================
# lab/grupal/uplinks-host.sh - une a R1-LAN (una VM) con el equipo de Squid
# (Est. 2) en la parte grupal. Se ejecuta en el HOST y necesita root.
#
# R1-LAN tiene un solo enlace con el resto del grupo: up-squid, el /30
# 192.168.84.0/30 de core/ADDRESSING.yaml (link_e1_e2). Este script crea:
#   - una interfaz TAP (tap-r1-squid): el extremo "del host" de la tarjeta de
#     la VM. lab.sh la usa sola si existe al arrancar R1.
#   - un bridge (br-xj-squid) que une ese TAP con el medio fisico.
# El host solo conmuta tramas: no tiene IP en el enlace ni enruta nada.
#
# Dos formas de llegar al equipo de Squid:
#   sudo ./uplinks-host.sh up --squid <NIC>
#         una tarjeta fisica (cable directo o a un switch)
#   sudo ./uplinks-host.sh up --vxlan <NIC> --squid-remoto <IP> [--vni <N>]
#         tunel VXLAN sobre la red de <NIC>, por ejemplo Wi-Fi (VNI 84 si no
#         se indica otro; el companero debe usar el mismo).
#         El MTU del enlace baja a 1450: en R1 hay que descomentar "mtu 1450"
#         en /etc/network/modos/grupal.
#   sudo ./uplinks-host.sh estado
#   sudo ./uplinks-host.sh down          deshace todo y devuelve la tarjeta
#
# Opciones de 'up':  --usuario <u>  dueno del TAP (por omision, quien llama a sudo)
#                    --sin-nm       no tocar NetworkManager
#
# Despues de 'up':  ./lab/lab.sh detener r1-lan && ./lab/lab.sh iniciar r1-lan
#                   y dentro de R1:  sudo r1-modo grupal
# =============================================================================
set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

ESTADO=/run/xelaju-uplinks.estado
TAP_SQUID=tap-r1-squid
BR_SQUID=br-xj-squid
IF_VXLAN=xjx-squid

info()  { echo "==> $*"; }
aviso() { echo "    [AVISO] $*" >&2; }
morir() { echo "    [ERROR] $*" >&2; exit 1; }
existe() { [ -d "/sys/class/net/$1" ]; }

uso() { sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-1}"; }

# ---- Tarjeta fisica y NetworkManager --------------------------------------------
# tomar_nic <NIC>: NetworkManager deja de gestionarla (si no, le pediria IP por
# DHCP o la sacaria del bridge) y se limpia su configuracion.
NICS_TOMADAS=""
tomar_nic() {
    local nic="$1"
    existe "$nic" || morir "no existe la interfaz $nic"
    if [ "$SIN_NM" -eq 0 ] && command -v nmcli >/dev/null && nmcli -t general status >/dev/null 2>&1; then
        if nmcli device set "$nic" managed no 2>/dev/null; then NICS_TOMADAS="$NICS_TOMADAS $nic"; fi
    fi
    ip addr flush dev "$nic"
    ip link set dev "$nic" up
}

# ---- TAP + bridge del enlace -------------------------------------------------------
crear_enlace() {    # crear_enlace <tap> <bridge>
    local tap="$1" br="$2"
    existe "$tap" || ip tuntap add dev "$tap" mode tap user "$USUARIO"
    existe "$br"  || ip link add name "$br" type bridge
    ip link set dev "$br" type bridge stp_state 0 forward_delay 0
    # El host no participa en el enlace: sin IPv6 automatica en el bridge
    sysctl -qw "net.ipv6.conf.$br.disable_ipv6=1" 2>/dev/null || true
    ip link set dev "$tap" master "$br"
    ip link set dev "$tap" up
    ip link set dev "$br" up
}

unir() {            # unir <interfaz> <bridge>
    ip link set dev "$1" master "$2"
    ip link set dev "$1" up
}

# ---- br_netfilter ------------------------------------------------------------------
# Con el modulo br_netfilter cargado (lo cargan Docker y otros), las tramas IP
# que cruzan un bridge pasan por la cadena FORWARD de iptables del host. Si su
# politica es DROP (Docker la pone asi), el bridge no conmutaria nada.
# Se agrega una regla que acepta solo lo que cruza NUESTRO bridge.
REGLA_FW=""
arreglar_br_netfilter() {
    local cadena=""
    [ "$(cat /proc/sys/net/bridge/bridge-nf-call-iptables 2>/dev/null || echo 0)" = 1 ] || return 0
    command -v iptables >/dev/null || { aviso "br_netfilter activo y no hay iptables: si no hay trafico, revise el cortafuegos del host"; return 0; }
    if iptables -S DOCKER-USER >/dev/null 2>&1; then cadena=DOCKER-USER
    elif iptables -S FORWARD 2>/dev/null | grep -q '^-P FORWARD DROP'; then cadena=FORWARD
    fi
    [ -n "$cadena" ] || return 0
    if ! iptables -C "$cadena" -i br-xj-+ -o br-xj-+ -j ACCEPT 2>/dev/null; then
        iptables -I "$cadena" -i br-xj-+ -o br-xj-+ -j ACCEPT
    fi
    REGLA_FW="$cadena"
    info "br_netfilter activo: regla ACCEPT para br-xj-* en la cadena $cadena"
}

# ---- up ------------------------------------------------------------------------------
cmd_up() {
    local squid="" vxlan="" squid_remoto="" vni=84 modo mtu
    USUARIO="${SUDO_USER:-root}"; SIN_NM=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --squid)        squid="${2:-}"; shift 2 ;;
            --vxlan)        vxlan="${2:-}"; shift 2 ;;
            --squid-remoto) squid_remoto="${2:-}"; shift 2 ;;
            --vni)          vni="${2:-}"; shift 2 ;;
            --usuario)      USUARIO="${2:-}"; shift 2 ;;
            --sin-nm)       SIN_NM=1; shift ;;
            *)              morir "opcion desconocida: $1" ;;
        esac
    done
    if [ -e "$ESTADO" ]; then morir "el enlace ya esta creado: use 'estado' o 'down'"; fi
    if [ -n "$vxlan" ]; then modo=vxlan; [ -n "$squid_remoto" ] || morir "--vxlan necesita --squid-remoto <IP>"
    elif [ -n "$squid" ]; then modo=fisico
    else uso 1; fi

    info "TAP y bridge (dueno del TAP: $USUARIO)"
    crear_enlace "$TAP_SQUID" "$BR_SQUID"

    case "$modo" in
        fisico)
            info "Enlace con Squid por $squid"
            tomar_nic "$squid"; unir "$squid" "$BR_SQUID"
            ;;
        vxlan)
            existe "$vxlan" || morir "no existe la interfaz $vxlan"
            mtu=$(( $(cat "/sys/class/net/$vxlan/mtu") - 50 ))     # 50 bytes de cabeceras VXLAN
            info "VXLAN (VNI $vni) sobre $vxlan hacia $squid_remoto (MTU del enlace: $mtu)"
            ip link add "$IF_VXLAN" type vxlan id "$vni" dstport 4789 remote "$squid_remoto" dev "$vxlan"
            unir "$IF_VXLAN" "$BR_SQUID"
            ip link set dev "$TAP_SQUID" mtu "$mtu"
            aviso "en R1 descomente 'mtu $mtu' en /etc/network/modos/grupal y repita 'r1-modo grupal'"
            aviso "el companero debe crear el mismo VNI apuntando a la IP de este host, y permitir UDP 4789"
            ;;
    esac

    arreglar_br_netfilter
    {
        echo "MODO=$modo"
        echo "NICS_TOMADAS=\"${NICS_TOMADAS# }\""
        echo "REGLA_FW=$REGLA_FW"
    } > "$ESTADO"

    cmd_estado
    echo
    echo "Siguiente paso:"
    echo "  1) Reiniciar la VM para que use el TAP:  ./lab/lab.sh detener r1-lan && ./lab/lab.sh iniciar r1-lan"
    echo "  2) Dentro de R1-LAN:                     sudo r1-modo grupal"
}

# ---- estado ----------------------------------------------------------------------------
cmd_estado() {
    if [ ! -e "$ESTADO" ]; then echo "Enlace grupal: no creado"; return 0; fi
    # shellcheck source=/dev/null
    . "$ESTADO"
    echo "Enlace grupal creado (modo $MODO)"
    if existe "$BR_SQUID"; then
        echo "  $BR_SQUID: $(ls "/sys/class/net/$BR_SQUID/brif" 2>/dev/null | tr '\n' ' ')"
    fi
    if existe "$TAP_SQUID"; then
        echo "  $TAP_SQUID: $(cat "/sys/class/net/$TAP_SQUID/operstate") (en uso por la VM solo si figura 'up')"
    fi
    [ -z "${NICS_TOMADAS:-}" ] || echo "  Tarjetas retiradas de NetworkManager: $NICS_TOMADAS"
    [ -z "${REGLA_FW:-}" ] || echo "  Regla de cortafuegos agregada en la cadena: $REGLA_FW"
}

# ---- down ------------------------------------------------------------------------------
cmd_down() {
    local i nic
    MODO=""; NICS_TOMADAS=""; REGLA_FW=""
    # shellcheck source=/dev/null
    [ -e "$ESTADO" ] && . "$ESTADO"
    if [ -n "$REGLA_FW" ] && command -v iptables >/dev/null; then
        iptables -D "$REGLA_FW" -i br-xj-+ -o br-xj-+ -j ACCEPT 2>/dev/null || true
    fi
    for i in "$IF_VXLAN" "$BR_SQUID"; do
        if existe "$i"; then ip link del dev "$i"; fi
    done
    if existe "$TAP_SQUID"; then ip tuntap del dev "$TAP_SQUID" mode tap; fi
    for nic in $NICS_TOMADAS; do
        nmcli device set "$nic" managed yes 2>/dev/null || aviso "no se pudo devolver $nic a NetworkManager"
    done
    rm -f "$ESTADO"
    info "Enlace grupal eliminado; el host queda como estaba"
}

orden="${1:-}"
[ $# -gt 0 ] && shift
case "$orden" in
    estado)         cmd_estado ;;
    -h|--help|"")   uso 0 ;;
    up|down)
        if [ "$(id -u)" -ne 0 ]; then morir "hay que ejecutarlo con sudo"; fi
        "cmd_$orden" "$@" ;;
    *)              uso 1 ;;
esac
