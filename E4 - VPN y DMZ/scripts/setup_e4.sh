#!/usr/bin/env bash
# ==============================================================================
# setup_e4.sh - aplica la parte de E4 del plan de direccionamiento del proyecto:
# enlace hacia E5, ruta por defecto, direcciones de la DMZ y reenvío de IP.
#
# Seguro por defecto: sin --apply solo imprime lo que haría.
# Idempotente: ejecutarlo de nuevo no cambia nada de lo que ya está aplicado.
#
#   setup_e4.sh --uplink <iface>                 simulación de la configuración
#   sudo setup_e4.sh --uplink <iface> --apply    aplica la configuración
#   setup_e4.sh --uplink <iface> --status        muestra el estado y comprobaciones básicas
#   sudo setup_e4.sh --uplink <iface> --teardown --apply   deshace lo que creó
#
#   --force-default   reemplaza una ruta por defecto existente que salga por otro lado
#
# Nunca toca interfaces distintas del enlace a E5 y de la interfaz dummy de la DMZ,
# nunca cambia una ruta por defecto existente salvo que se pase --force-default, y
# no levanta WireGuard (wg0.conf contiene la llave privada).
# ==============================================================================
set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${E4_ENV_FILE:-$SCRIPT_DIR/../config/e4.env}"
# shellcheck source=/dev/null
. "$ENV_FILE"

MODE="dry-run"
ACTION="setup"
FORCE_DEFAULT=0

usage() { sed -n '2,19p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
die() { echo "ERROR: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --apply)         MODE="apply" ;;
        --dry-run)       MODE="dry-run" ;;
        --status)        ACTION="status" ;;
        --teardown)      ACTION="teardown" ;;
        --force-default) FORCE_DEFAULT=1 ;;
        --uplink)        UPLINK_IFACE="${2:?--uplink necesita el nombre de una interfaz}"; shift ;;
        -h|--help)       usage; exit 0 ;;
        *)               usage >&2; die "opción desconocida: $1" ;;
    esac
    shift
done

[ -n "$UPLINK_IFACE" ] || die "no se definió la interfaz de enlace: edite config/e4.env o use --uplink <iface>"
ip link show "$UPLINK_IFACE" >/dev/null 2>&1 || die "la interfaz '$UPLINK_IFACE' no existe en este equipo"
if [ "$MODE" = "apply" ] && [ "$ACTION" != "status" ] && [ "$(id -u)" -ne 0 ]; then
    die "--apply requiere root (use sudo)"
fi

run() {
    if [ "$MODE" = "apply" ]; then echo "+ $*"; "$@"; else echo "[dry-run] $*"; fi
}
ok()   { echo "ok    $*"; }
warn() { echo "WARN  $*"; }

has_addr() { ip -4 -o addr show dev "$1" 2>/dev/null | awk '{print $4}' | grep -x "$2" >/dev/null; }

default_routes() { ip -4 route show default 2>/dev/null || true; }

# ---- setup -------------------------------------------------------------------
do_setup() {
    echo "== 1. Reenvío de IP"
    if [ "$(cat /proc/sys/net/ipv4/ip_forward)" = "1" ]; then ok "net.ipv4.ip_forward=1"; else run sysctl -w net.ipv4.ip_forward=1; fi
    if [ -f "$SYSCTL_CONF" ] && grep -qx "net.ipv4.ip_forward=1" "$SYSCTL_CONF"; then
        ok "persistente en $SYSCTL_CONF"
    elif [ "$MODE" = "apply" ]; then
        echo "net.ipv4.ip_forward=1" > "$SYSCTL_CONF"; echo "+ escrito $SYSCTL_CONF"
    else
        echo "[dry-run] escribir 'net.ipv4.ip_forward=1' en $SYSCTL_CONF"
    fi

    echo "== 2. Enlace hacia E5 ($UPLINK_IFACE)"
    if has_addr "$UPLINK_IFACE" "$UPLINK_IP"; then ok "$UPLINK_IP ya está en $UPLINK_IFACE"; else run ip addr replace "$UPLINK_IP" dev "$UPLINK_IFACE"; fi
    run ip link set "$UPLINK_IFACE" up
    if [ "$(ip -4 -o addr show dev "$UPLINK_IFACE" | wc -l)" -gt 1 ]; then
        warn "$UPLINK_IFACE tiene otras direcciones IPv4 además de $UPLINK_IP (no se tocan)"
    fi

    echo "== 3. Ruta por defecto vía E5 ($UPLINK_GW)"
    local current; current="$(default_routes)"
    if grep -q "via $UPLINK_GW dev $UPLINK_IFACE" <<<"$current"; then
        ok "ya existe: default via $UPLINK_GW dev $UPLINK_IFACE"
    elif [ -z "$current" ] || [ "$FORCE_DEFAULT" -eq 1 ]; then
        run ip route replace default via "$UPLINK_GW" dev "$UPLINK_IFACE"
    else
        warn "ya hay otra ruta por defecto, NO se cambia (cortaría la conectividad actual):"
        echo "$current" | sed 's/^/        /'
        warn "cuando esté conectado a E5 y sin otra salida, repita con --force-default"
    fi

    echo "== 4. DMZ en $DMZ_IFACE (interfaz dummy, sin segunda tarjeta de red física)"
    if ip link show "$DMZ_IFACE" >/dev/null 2>&1; then ok "$DMZ_IFACE existe"; else run ip link add "$DMZ_IFACE" type dummy; fi
    run ip link set "$DMZ_IFACE" up
    local a
    for a in "$DMZ_GW_IP" "$WEB01_IP"; do
        if has_addr "$DMZ_IFACE" "$a"; then ok "$a ya está en $DMZ_IFACE"; else run ip addr replace "$a" dev "$DMZ_IFACE"; fi
    done

    echo "== 5. WireGuard ($WG_IFACE)"
    if ip link show "$WG_IFACE" >/dev/null 2>&1; then
        for a in $WG_ADDRS; do
            if has_addr "$WG_IFACE" "$a"; then ok "$a en $WG_IFACE"; else warn "falta $a en $WG_IFACE: revise Address en /etc/wireguard/$WG_IFACE.conf"; fi
        done
    else
        warn "$WG_IFACE no está levantada. Levántela con: sudo wg-quick up $WG_IFACE"
    fi
}

# ---- status ------------------------------------------------------------------
do_status() {
    local fails=0
    chk() { if "$@" >/dev/null 2>&1; then echo "PASS  $DESC"; else echo "FAIL  $DESC"; fails=$((fails + 1)); fi; }
    DESC="ip_forward activo";                       chk test "$(cat /proc/sys/net/ipv4/ip_forward)" = "1"
    DESC="$UPLINK_IP en $UPLINK_IFACE";             chk has_addr "$UPLINK_IFACE" "$UPLINK_IP"
    DESC="ruta por defecto vía $UPLINK_GW";         chk bash -c "ip -4 route show default | grep 'via $UPLINK_GW dev $UPLINK_IFACE' >/dev/null"
    DESC="$DMZ_GW_IP en $DMZ_IFACE";                chk has_addr "$DMZ_IFACE" "$DMZ_GW_IP"
    DESC="$WEB01_IP en $DMZ_IFACE";                 chk has_addr "$DMZ_IFACE" "$WEB01_IP"
    local a; for a in $WG_ADDRS; do DESC="$a en $WG_IFACE"; chk has_addr "$WG_IFACE" "$a"; done
    DESC="alcanza al gateway $UPLINK_GW (E5)";      chk ping -c1 -W1 "$UPLINK_GW"
    DESC="Zabbix 192.168.30.10 sale vía $UPLINK_GW"; chk bash -c "ip route get 192.168.30.10 | grep 'via $UPLINK_GW' >/dev/null"
    echo "Fallos: $fails"
    return "$fails"
}

# ---- teardown ----------------------------------------------------------------
do_teardown() {
    echo "== Deshaciendo lo que crea este script (no toca ip_forward ni $SYSCTL_CONF)"
    if ip -4 route show default | grep "via $UPLINK_GW dev $UPLINK_IFACE" >/dev/null; then run ip route del default via "$UPLINK_GW" dev "$UPLINK_IFACE"; else ok "no hay ruta por defecto vía $UPLINK_GW que quitar"; fi
    if ip link show "$DMZ_IFACE" >/dev/null 2>&1; then run ip link del "$DMZ_IFACE"; else ok "$DMZ_IFACE no existe"; fi
    if has_addr "$UPLINK_IFACE" "$UPLINK_IP"; then run ip addr del "$UPLINK_IP" dev "$UPLINK_IFACE"; else ok "$UPLINK_IP no está en $UPLINK_IFACE"; fi
}

if [ "$ACTION" = "status" ]; then echo "Acción: status | uplink: $UPLINK_IFACE"; else echo "Modo: $MODE | acción: $ACTION | uplink: $UPLINK_IFACE"; fi
case "$ACTION" in
    setup)    do_setup ;;
    status)   do_status ;;
    teardown) do_teardown ;;
esac
