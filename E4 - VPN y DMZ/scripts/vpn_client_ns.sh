#!/usr/bin/env bash
# ==============================================================================
# vpn_client_ns.sh - un cliente WireGuard dentro de un network namespace del equipo E4.
#
# Permite a E4 probar sus propias políticas de VPN desde una línea de comandos real
# (ping, nc, curl) sin teléfono. El cliente vive en un namespace privado unido al
# equipo por un par veth y marca al wg0 de este mismo equipo en la dirección del veth.
# La red del equipo (ruta por defecto, DNS, cualquier otra VPN) nunca se toca.
# Requiere root.
#
#   sudo vpn_client_ns.sh up <peer> [--as-ip A.B.C.D] [--dry-run]
#   sudo vpn_client_ns.sh exec [comando...]    lo ejecuta como ese cliente (por defecto: bash)
#   sudo vpn_client_ns.sh status
#   sudo vpn_client_ns.sh down
#
# <peer> es un perfil creado por gen_peers.sh (admin1, user1, ...). Su llave privada se
# lee del directorio de llaves y se pasa a wg por una tubería: nunca se imprime ni se copia.
# --as-ip   envía con otra dirección de origen distinta de la del perfil. Prueba de
#           suplantación: WireGuard debe descartar el paquete, porque la dirección queda
#           fuera de los AllowedIPs de ese peer.
# Opciones de up: --keys-dir DIR | --dry-run
#
# Cubre la segunda pasada del flujo B (tráfico descifrado hacia E5). La primera pasada
# (DNAT de E3, UDP/51820 en E5) necesita un cliente en la red del ISP1, como el teléfono.
# ==============================================================================
set -Eeuo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${E4_ENV_FILE:-$SCRIPT_DIR/../config/e4.env}"
# shellcheck source=/dev/null
. "$ENV_FILE"

NS="${E4_CLIENT_NS:-xj-vpnc}"
H_IF="xjvc-h"                                   # extremo del par veth en el equipo
C_IF="xjvc-c"                                   # extremo dentro del namespace
WG_C="wgc"                                      # interfaz WireGuard dentro del namespace
H_IP="${E4_CLIENT_HOST_IP:-10.99.0.1}"          # enlace /30 entre el equipo y el namespace
C_IP="${E4_CLIENT_NS_IP:-10.99.0.2}"
STATE="/run/xj-vpnc"
DRY=0
AS_IP=""

usage() { sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
die()  { echo "ERROR: $*" >&2; exit 1; }
ok()   { echo "ok    $*"; }
warn() { echo "WARN  $*"; }
run()  { if [ "$DRY" -eq 1 ]; then echo "[dry-run] $*"; else "$@"; fi; }

need_root() { [ "$DRY" -eq 1 ] || [ "$(id -u)" -eq 0 ] || die "requiere root: sudo $0 $ACTION ..."; }

INVOKER="${SUDO_USER:-$(id -un)}"
HOME_DIR="$(getent passwd "$INVOKER" | cut -d: -f6 || true)"
HOME_DIR="${HOME_DIR:-$HOME}"
KEYS_DIR="${E4_KEYS_DIR:-$HOME_DIR/.local/share/xelaju-e4/wireguard}"

# un namespace real, no solo un archivo sobrante en /run/netns
ns_exists() { ip -n "$NS" link show lo >/dev/null 2>&1; }

do_down() {
    ns_exists && run ip netns del "$NS" 2>/dev/null || true
    ip link show "$H_IF" >/dev/null 2>&1 && run ip link del "$H_IF" 2>/dev/null || true
    [ "$DRY" -eq 1 ] || rm -rf "$STATE"
}

do_up() {
    local peer="$1" conf addr ip dns allowed a gw hs
    conf="$KEYS_DIR/$peer.conf"
    [ -r "$conf" ] || die "no existe el perfil '$conf' (créelo con: gen_peers.sh --endpoint HOST:PUERTO --apply)"
    command -v wg >/dev/null 2>&1 && command -v wg-quick >/dev/null 2>&1 || die "wireguard-tools no está instalado"
    ip link show "${WG_IFACE:-wg0}" >/dev/null 2>&1 || [ "$DRY" -eq 1 ] \
        || die "la interfaz del servidor ${WG_IFACE:-wg0} está caída en este equipo (sudo wg-quick up ${WG_IFACE:-wg0})"

    addr="$(sed -n 's/^Address *= *//p' "$conf" | head -1)"
    [ -n "$addr" ] || die "$conf no tiene Address"
    ip="${AS_IP:-${addr%%/*}}"
    dns="$(sed -n 's/^DNS *= *//p' "$conf" | head -1 | cut -d, -f1 | tr -d ' ')"
    allowed="$(sed -n 's/^AllowedIPs *= *//p' "$conf" | head -1 | tr ',' ' ')"

    if ns_exists && [ "$DRY" -eq 0 ]; then
        if [ "$(cat "$STATE/peer" 2>/dev/null)" = "$peer/$ip" ]; then
            ok "el cliente $peer ($ip) ya está levantado en el namespace $NS"; return 0
        fi
        die "el namespace $NS está levantado para otro cliente ($(cat "$STATE/peer" 2>/dev/null)): ejecute primero '$0 down'"
    fi

    trap 'echo "ERROR: falló up, se elimina el namespace parcial" >&2; do_down' ERR
    run mkdir -p "$STATE"
    [ "$DRY" -eq 1 ] || { chmod 700 "$STATE"; echo "$peer/$ip" > "$STATE/peer"; }
    [ "$DRY" -eq 1 ] || printf 'nameserver %s\n' "${dns:-8.8.8.8}" > "$STATE/resolv.conf"

    run ip netns add "$NS"
    run ip -n "$NS" link set lo up
    run ip link add "$H_IF" type veth peer name "$C_IF" netns "$NS"
    run ip addr add "$H_IP/30" dev "$H_IF"
    run ip link set "$H_IF" up
    run ip -n "$NS" addr add "$C_IP/30" dev "$C_IF"
    run ip -n "$NS" link set "$C_IF" up

    run ip -n "$NS" link add "$WG_C" type wireguard
    # wg-quick strip descarta Address/DNS; el endpoint se reemplaza por la dirección del
    # veth de este equipo. La llave privada viaja solo por la tubería.
    if [ "$DRY" -eq 1 ]; then
        echo "[dry-run] wg-quick strip $conf | (Endpoint -> $H_IP:${WG_PORT:-51820}) | ip netns exec $NS wg setconf $WG_C /dev/stdin"
    else
        wg-quick strip "$conf" \
            | sed -E "s|^Endpoint *=.*|Endpoint = $H_IP:${WG_PORT:-51820}|" \
            | ip netns exec "$NS" wg setconf "$WG_C" /dev/stdin
    fi
    run ip -n "$NS" addr add "$ip/32" dev "$WG_C"
    run ip -n "$NS" link set "$WG_C" up
    for a in $allowed; do
        case "$a" in
            *:*) ;;                                                # IPv6: no se enruta en el laboratorio
            0.0.0.0/0) run ip -n "$NS" route add default dev "$WG_C" ;;
            *)         run ip -n "$NS" route add "$a" dev "$WG_C" ;;
        esac
    done
    trap - ERR

    if [ "$DRY" -eq 1 ]; then return 0; fi
    gw="${ip%.*}.1"
    ip netns exec "$NS" ping -c1 -W2 "$gw" >/dev/null 2>&1 || true
    hs="$(ip netns exec "$NS" wg show "$WG_C" latest-handshakes | awk '{print $2}')"
    ok "cliente $peer levantado en el namespace $NS: dirección $ip, lado del servidor $gw, DNS ${dns:-8.8.8.8}"
    if [ "${hs:-0}" -gt 0 ]; then ok "handshake completado"; else warn "aún no hay handshake (revise: sudo wg show ${WG_IFACE:-wg0})"; fi
    [ -z "$AS_IP" ] || warn "--as-ip $ip: es una prueba de suplantación, NO se esperan respuestas"
    echo "Uso:  sudo $0 exec ping -c1 <host>   |   sudo $0 down"
}

do_exec() {
    ns_exists || die "no hay ningún cliente levantado: sudo $0 up <peer>"
    [ $# -gt 0 ] || set -- bash
    # resolv.conf propio para el cliente, en un espacio de montajes privado (el del equipo no se toca)
    exec ip netns exec "$NS" unshare -m bash -c '
        T="$(readlink -f /etc/resolv.conf)"
        [ -e "$T" ] || { mkdir -p "$(dirname "$T")"; : > "$T"; }
        mount --bind "$1" "$T" && shift && exec "$@"' _ "$STATE/resolv.conf" "$@"
}

do_status() {
    if ! ns_exists; then echo "Ningún cliente levantado (el namespace $NS no existe)."; return 0; fi
    echo "Cliente: $(cat "$STATE/peer" 2>/dev/null || echo '?')  namespace: $NS"
    ip -n "$NS" -br addr show "$WG_C" 2>/dev/null || true
    ip netns exec "$NS" wg show "$WG_C" 2>/dev/null | grep -v -i 'private' || true
}

# ---- argumentos -------------------------------------------------------------------
[ $# -gt 0 ] || { usage; exit 1; }
ACTION="$1"; shift
case "$ACTION" in
    -h|--help) usage; exit 0 ;;
    exec)      need_root; do_exec "$@"; exit $? ;;
    status)    need_root; do_status; exit 0 ;;
    down)      need_root; do_down; ok "namespace $NS eliminado (si existía)"; exit 0 ;;
    up)        ;;
    *)         usage >&2; die "acción desconocida: $ACTION" ;;
esac

PEER="${1:-}"; [ -n "$PEER" ] || { usage >&2; die "up necesita el nombre de un peer"; }
shift
while [ $# -gt 0 ]; do
    case "$1" in
        --as-ip)    AS_IP="${2:?--as-ip necesita una dirección}"; shift ;;
        --keys-dir) KEYS_DIR="${2:?--keys-dir necesita un directorio}"; shift ;;
        --dry-run)  DRY=1 ;;
        *)          usage >&2; die "opción desconocida: $1" ;;
    esac
    shift
done
need_root
do_up "$PEER"
