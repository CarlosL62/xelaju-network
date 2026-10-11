#!/usr/bin/env bash
# ==============================================================================
# gen_peers.sh - (re)genera los peers de prueba de WireGuard de E4.
#
# Las llaves privadas y los perfiles de cliente van a un directorio privado FUERA del
# repositorio (por defecto ~/.local/share/xelaju-e4/wireguard, modo 700). Las llaves
# privadas nunca se imprimen. Simulación salvo que se pase --apply. Idempotente: las
# llaves existentes se conservan salvo que se pase --regen.
#
# Paso 1 (con su usuario, sin sudo): llaves + perfiles de cliente
#   gen_peers.sh --endpoint HOST:PUERTO --apply
# Paso 2 (sudo): pone los peers en /etc/wireguard/wg0.conf (conserva su [Interface],
#   hace una copia de respaldo y sincroniza un wg0 en marcha sin tumbarlo)
#   sudo gen_peers.sh --install-server --apply
# Extras:
#   gen_peers.sh --qr <peer>        QR del perfil de cliente para un teléfono, dibujado en la
#                                   terminal (requiere qrencode; unas 33 filas x 65 columnas).
#                                   Codifica la llave privada: al pulsar Enter se borra la
#                                   pantalla. No se escribe nada en disco.
#   gen_peers.sh --qr <peer> --png  igual, pero como archivo de imagen en el directorio de
#                                   llaves (también contiene la llave privada: bórrelo después)
#   gen_peers.sh --print-docs       tabla markdown + bloques de peers (solo llaves públicas)
#                                   para actualizar el README y server.conf.example
# Opciones: --regen  llaves nuevas aunque existan | --keys-dir DIR | --endpoint H:P | --png
#           --suffix NOMBRE  escribe <peer>-NOMBRE.conf en lugar de <peer>.conf, con las mismas
#                            llaves y otro endpoint (p. ej. --suffix isp2 para un segundo ISP).
#                            Un perfil tiene un solo Endpoint, así que cada vía de entrada
#                            necesita su propio archivo; --qr admin1-isp2 lo dibuja
# ==============================================================================
set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${E4_ENV_FILE:-$SCRIPT_DIR/../config/e4.env}"
# shellcheck source=/dev/null
. "$ENV_FILE"

MODE="dry-run"
ACTION="generate"
REGEN=0
QR_PEER=""
QR_PNG=0
SUFFIX=""

usage() { sed -n '2,29p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
die()  { echo "ERROR: $*" >&2; exit 1; }
ok()   { echo "ok    $*"; }
warn() { echo "WARN  $*"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --apply)          MODE="apply" ;;
        --dry-run)        MODE="dry-run" ;;
        --install-server) ACTION="install-server" ;;
        --print-docs)     ACTION="print-docs" ;;
        --qr)             ACTION="qr"; QR_PEER="${2:?--qr necesita el nombre de un peer}"; shift ;;
        --png)            QR_PNG=1 ;;
        --suffix)         case "${2:-}" in ""|*[!a-z0-9]*) die "--suffix necesita un nombre de letras minúsculas y dígitos" ;; esac; SUFFIX="-$2"; shift ;;
        --regen)          REGEN=1 ;;
        --keys-dir)       E4_KEYS_DIR="${2:?--keys-dir necesita un directorio}"; shift ;;
        --endpoint)       WG_ENDPOINT="${2:?--endpoint necesita HOST:PUERTO}"; shift ;;
        -h|--help)        usage; exit 0 ;;
        *)                usage >&2; die "opción desconocida: $1" ;;
    esac
    shift
done

command -v wg >/dev/null 2>&1 || die "wireguard-tools no está instalado (sudo apt install wireguard-tools)"

# ---- ubicaciones -----------------------------------------------------------------
INVOKER="${SUDO_USER:-$(id -un)}"
HOME_DIR="$(getent passwd "$INVOKER" | cut -d: -f6 || true)"
HOME_DIR="${HOME_DIR:-$HOME}"
KEYS_DIR="${E4_KEYS_DIR:-$HOME_DIR/.local/share/xelaju-e4/wireguard}"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
if [ -n "$REPO_ROOT" ]; then
    case "$(readlink -m "$KEYS_DIR")/" in
        "$REPO_ROOT"/*) die "el directorio de llaves '$KEYS_DIR' está dentro del repositorio git: los secretos nunca se versionan" ;;
    esac
fi
ENDPOINT="${WG_ENDPOINT:-ENDPOINT_PENDIENTE:$WG_PORT}"
CONF="$WG_CONF_DIR/${WG_IFACE:-wg0}.conf"

peer_name() { echo "${1%%:*}"; }
peer_ip()   { echo "${1##*:}"; }
peer_type() { case "$1" in admin*) echo "VPN-ADMIN" ;; *) echo "VPN-USERS" ;; esac; }
priv_file() { echo "$KEYS_DIR/$1.private.key"; }
pub_file()  { echo "$KEYS_DIR/$1.public.key"; }

# ---- generar ------------------------------------------------------------------
do_generate() {
    [ -z "${SUDO_USER:-}" ] || die "generar llaves no debe ejecutarse con sudo: quedarían a nombre de root"
    echo "Directorio de llaves: $KEYS_DIR"
    case "$ENDPOINT" in ENDPOINT_PENDIENTE:*) warn "sin --endpoint: los perfiles llevan un marcador visible; repita con --endpoint cuando se conozca" ;; esac
    if [ "$MODE" = "apply" ]; then mkdir -p "$KEYS_DIR"; chmod 700 "$KEYS_DIR"; fi

    local entry name ip
    for entry in $WG_PEERS; do
        name="$(peer_name "$entry")"; ip="$(peer_ip "$entry")"
        if [ -s "$(priv_file "$name")" ] && [ "$REGEN" -eq 0 ]; then
            ok "$name: llaves conservadas"
        elif [ "$MODE" = "apply" ]; then
            ( umask 077; wg genkey > "$(priv_file "$name")"; wg pubkey < "$(priv_file "$name")" > "$(pub_file "$name")" )
            echo "+ $name: par de llaves nuevo"
        else
            echo "[dry-run] $name: generar par de llaves"
        fi
        if [ "$MODE" = "apply" ]; then
            ( umask 077
              {
                  echo "[Interface]"
                  echo "PrivateKey = $(cat "$(priv_file "$name")")"
                  echo "Address = $ip/32"
                  if [ -n "$WG_CLIENT_DNS" ]; then echo "DNS = $WG_CLIENT_DNS"; fi
                  echo
                  echo "[Peer]"
                  echo "PublicKey = $WG_SERVER_PUBKEY"
                  echo "Endpoint = $ENDPOINT"
                  echo "AllowedIPs = $WG_CLIENT_ALLOWED_IPS"
                  echo "PersistentKeepalive = 25"
              } > "$KEYS_DIR/$name$SUFFIX.conf" )
            echo "+ $name: perfil de cliente -> $KEYS_DIR/$name$SUFFIX.conf ($(peer_type "$name"), $ip, endpoint $ENDPOINT)"
        else
            echo "[dry-run] $name: escribir perfil de cliente $KEYS_DIR/$name$SUFFIX.conf ($(peer_type "$name"), $ip, endpoint $ENDPOINT)"
        fi
    done
    echo "Siguiente: sudo $0 --install-server --apply"
}

# ---- install-server --------------------------------------------------------------
peer_blocks() {
    local entry name
    for entry in $WG_PEERS; do
        name="$(peer_name "$entry")"
        [ -s "$(pub_file "$name")" ] || die "no hay llave pública de '$name' en $KEYS_DIR: ejecute primero $0 --endpoint HOST:PUERTO --apply"
        echo "# Peer: $name ($(peer_type "$name"))"
        echo "[Peer]"
        echo "PublicKey = $(cat "$(pub_file "$name")")"
        echo "AllowedIPs = $(peer_ip "$entry")/32"
        echo
    done
}

do_install_server() {
    local blocks; blocks="$(peer_blocks)"
    if [ "$MODE" != "apply" ]; then
        echo "[dry-run] conservaría el [Interface] de $CONF, haría una copia de respaldo y reemplazaría TODOS los peers por:"
        echo "$blocks" | sed 's/^/          /'
        [ -r "$CONF" ] || warn "$CONF no se puede leer sin sudo; la ejecución real comprueba primero la llave del servidor y el [Interface]"
        return 0
    fi
    [ "$(id -u)" -eq 0 ] || die "--install-server --apply requiere root (use sudo)"
    [ -r "$CONF" ] || die "$CONF no existe"

    local derived
    derived="$(awk '/^PrivateKey *=/{print $3; exit}' "$CONF" | wg pubkey)"
    [ "$derived" = "$WG_SERVER_PUBKEY" ] || die "la llave pública del servidor derivada de $CONF no coincide con WG_SERVER_PUBKEY de e4.env"
    ok "la llave del servidor en $CONF coincide con WG_SERVER_PUBKEY"

    local tmpd; tmpd="$(mktemp -d "$WG_CONF_DIR/.gen-peers.XXXXXX")"
    trap "rm -rf '$tmpd'" EXIT
    local new="$tmpd/${WG_IFACE:-wg0}.conf"
    ( umask 077
      awk '/^# Peer:/ || /^\[Peer\]/ {exit} {print}' "$CONF" | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}' > "$new"
      printf '\n%s\n' "$blocks" >> "$new" )
    wg-quick strip "$new" >/dev/null || die "la nueva configuración no valida; no se cambió nada"
    ok "la nueva configuración valida"

    local bak; bak="$CONF.bak-$(date +%Y%m%d-%H%M%S)"
    cp -p "$CONF" "$bak"; echo "+ respaldo: $bak"
    install -m 600 "$new" "$CONF"; echo "+ $CONF actualizado"
    if ip link show "${WG_IFACE:-wg0}" >/dev/null 2>&1; then
        wg syncconf "${WG_IFACE:-wg0}" <(wg-quick strip "$CONF"); echo "+ ${WG_IFACE:-wg0} en marcha sincronizado (sin reiniciar)"
    else
        ok "${WG_IFACE:-wg0} está caída: usará los peers nuevos cuando se levante (sudo wg-quick up ${WG_IFACE:-wg0})"
    fi
}

# ---- qr --------------------------------------------------------------------------
do_qr() {
    [ -z "${SUDO_USER:-}" ] || die "--qr no debe ejecutarse con sudo"
    command -v qrencode >/dev/null 2>&1 || die "qrencode no está instalado (sudo apt install qrencode)"
    local conf="$KEYS_DIR/$QR_PEER.conf"
    [ -s "$conf" ] || die "no hay perfil de cliente de '$QR_PEER' en $KEYS_DIR: ejecute primero $0 --endpoint HOST:PUERTO --apply"

    if [ "$QR_PNG" -eq 1 ]; then
        if [ "$MODE" != "apply" ]; then echo "[dry-run] qrencode -r $conf -o $KEYS_DIR/qr/$QR_PEER.png"; return 0; fi
        ( umask 077; mkdir -p "$KEYS_DIR/qr"; qrencode -r "$conf" -o "$KEYS_DIR/qr/$QR_PEER.png" -t PNG )
        echo "+ $KEYS_DIR/qr/$QR_PEER.png (contiene la llave privada: bórrelo después de escanearlo)"
        return 0
    fi

    if [ "$MODE" != "apply" ]; then echo "[dry-run] qrencode -t ANSIUTF8 -r $conf   (se dibuja en esta terminal; no se escribe nada)"; return 0; fi
    [ -t 1 ] && [ -t 0 ] || die "--qr dibuja en la terminal y necesita una interactiva (use --png para un archivo)"
    local qr rows cols need_r need_c
    qr="$(qrencode -t ANSIUTF8 -r "$conf")"
    need_r="$(printf '%s\n' "$qr" | wc -l)"
    need_c="$(printf '%s\n' "$qr" | sed 's/\x1b\[[0-9;]*m//g' | awk '{ if (length($0) > m) m = length($0) } END { print m }')"
    read -r rows cols < <(stty size 2>/dev/null || echo "0 0")
    if [ "$rows" -gt 0 ] && { [ "$rows" -lt "$need_r" ] || [ "$cols" -lt "$need_c" ]; }; then
        warn "la terminal mide ${cols}x${rows} y el QR necesita ${need_c}x${need_r}: se cortaría y no se podría escanear. Reduzca la fuente, agrande la ventana o use --png"
        read -r -p "Pulse Enter para dibujarlo de todos modos, Ctrl+C para cancelar " _
    fi
    clear
    printf '%s\n' "$qr"
    echo "QR de '$QR_PEER' (codifica la llave privada). Escanéelo con la app de WireGuard."
    read -r -p "Pulse Enter al terminar: se borra la pantalla " _
    clear
    echo "QR borrado de la pantalla. No se escribió nada en disco."
}

# ---- print-docs ------------------------------------------------------------------
do_print_docs() {
    local entry name
    echo "| Peer | Tipo | IP de la VPN | Llave pública |"
    echo "|---|---|---|---|"
    for entry in $WG_PEERS; do
        name="$(peer_name "$entry")"
        [ -s "$(pub_file "$name")" ] || die "no hay llave pública de '$name' en $KEYS_DIR"
        echo "| $name | $(peer_type "$name") | \`$(peer_ip "$entry")/32\` | \`$(cat "$(pub_file "$name")")\` |"
    done
    echo
    peer_blocks
}

case "$ACTION" in
    generate)       do_generate ;;
    install-server) do_install_server ;;
    qr)             do_qr ;;
    print-docs)     do_print_docs ;;
esac
