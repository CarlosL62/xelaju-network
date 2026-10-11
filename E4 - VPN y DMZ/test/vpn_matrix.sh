#!/usr/bin/env bash
# ==============================================================================
# vpn_matrix.sh - matriz de pruebas de E4: políticas de acceso de la VPN y aislamiento de la DMZ.
#
#   sudo vpn_matrix.sh <peer>   levanta el peer (admin1, user1, ...) en un namespace de cliente
#                               (scripts/vpn_client_ns.sh), ejecuta sus casos y elimina el
#                               namespace. admin* = VPN-ADMIN, cualquier otro = VPN-USERS.
#   sudo vpn_matrix.sh dmz      casos de la DMZ, ejecutados desde este equipo con la dirección de WEB01
#   Opciones: --skip-r1   omite los casos que decide R1 (ACL de E1), para un laboratorio solo con E5
#             --no-spoof  omite el caso anti-suplantación de los peers VPN-USERS
#             --keep      deja el namespace del cliente levantado al terminar
#             --out DIR   dónde se guarda el archivo de resultados (por defecto
#                         ~/.local/share/xelaju-e4/results, fuera del repositorio)
#
# Los casos son la matriz de pruebas del grupo (E1) más las comprobaciones propias de E4.
# Cada línea indica quién decide: [E5] firewall perimetral, [R1] ACL de la LAN, [E4] el propio WireGuard.
# Código de salida 1 si algún caso falla. Al final se listan las pruebas que requieren otros nodos.
# ==============================================================================
set -uo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLIENT="$(readlink -f "$SCRIPT_DIR/../scripts/vpn_client_ns.sh")"
ENV_FILE="${E4_ENV_FILE:-$SCRIPT_DIR/../config/e4.env}"
# shellcheck source=/dev/null
. "$ENV_FILE"

# Hosts de la red del grupo (plan de direccionamiento y matriz de pruebas de E1)
: "${H_ADMIN:=192.168.10.50}"      # PC-ADMIN01, solo responde ping
: "${H_USER:=192.168.20.10}"       # PC-USER01, SSH
: "${H_ZBX:=192.168.30.10}"        # servidor Zabbix
: "${H_INTRA:=192.168.30.20}"      # SRV-INTRA01, HTTP y HTTPS
: "${H_SW:=192.168.40.2}"          # SW-CORE01, SSH
: "${H_WEB01:=172.16.10.10}"       # WEB01 en la DMZ
: "${H_NET:=1.1.1.1}"              # una dirección de Internet alcanzable por TCP/443
: "${CURL_OPTS:=}"                 # opciones extra de curl (un laboratorio con certificados autofirmados usa -k)

TARGET=""
SKIP_R1=0; SPOOF=1; KEEP=0
INVOKER="${SUDO_USER:-$(id -un)}"
HOME_DIR="$(getent passwd "$INVOKER" | cut -d: -f6 || true)"; HOME_DIR="${HOME_DIR:-$HOME}"
OUT_DIR="$HOME_DIR/.local/share/xelaju-e4/results"
KEYS_DIR="${E4_KEYS_DIR:-$HOME_DIR/.local/share/xelaju-e4/wireguard}"

usage() { sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
die()   { echo "ERROR: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --skip-r1)  SKIP_R1=1 ;;
        --no-spoof) SPOOF=0 ;;
        --keep)     KEEP=1 ;;
        --out)      OUT_DIR="${2:?--out necesita un directorio}"; shift ;;
        -h|--help)  usage; exit 0 ;;
        -*)         usage >&2; die "opción desconocida: $1" ;;
        *)          [ -z "$TARGET" ] || die "solo se admite un objetivo"; TARGET="$1" ;;
    esac
    shift
done
[ -n "$TARGET" ] || { usage >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || die "requiere root: sudo $0 $TARGET"
[ -x "$CLIENT" ] || die "no se encontró: $CLIENT"

mkdir -p "$OUT_DIR"
OUT_FILE="$OUT_DIR/$(date +%Y%m%d-%H%M%S)-$TARGET.txt"
: > "$OUT_FILE"
emit() { printf '%s\n' "$*" | tee -a "$OUT_FILE"; }

trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; printf '%s' "${s%"${s##*[![:space:]]}"}"; }

# ---- sondas ------------------------------------------------------------------------
# Cada una imprime OK / BLOQUEADO (comprobaciones de acceso), un código HTTP, u OK / FALLA (comprobaciones de estado).
in_client() { "$CLIENT" exec "$@"; }

tcp_probe()  { timeout 4 bash -c "exec 3<>/dev/tcp/$1/$2" >/dev/null 2>&1 && echo OK || echo BLOQUEADO; }
tcp_src()    { python3 -c 'import socket,sys
s=socket.socket(); s.settimeout(4); s.bind((sys.argv[1],0)); s.connect((sys.argv[2],int(sys.argv[3])))' "$1" "$2" "$3" >/dev/null 2>&1 && echo OK || echo BLOQUEADO; }
http_code()  { local code; code="$("$@" 2>/dev/null)"; echo "${code:-000}"; }

probe() {  # probe <dónde: ns|host> <tipo> <destino> <puerto> [origen]
    local where="$1" tipo="$2" dest="$3" port="$4" src="${5:-}" host path url
    host="${dest%%/*}"; path="/"; [[ "$dest" == */* ]] && path="/${dest#*/}"
    case "$tipo" in
        ping)  if [ "$where" = ns ]; then in_client ping -c1 -W2 "$dest" >/dev/null 2>&1 && echo OK || echo BLOQUEADO
               else ping -c1 -W2 ${src:+-I "$src"} "$dest" >/dev/null 2>&1 && echo OK || echo BLOQUEADO; fi ;;
        tcp)   if [ "$where" = ns ]; then in_client timeout 4 bash -c "exec 3<>/dev/tcp/$dest/$port" >/dev/null 2>&1 && echo OK || echo BLOQUEADO
               elif [ -n "$src" ]; then tcp_src "$src" "$dest" "$port"; else tcp_probe "$dest" "$port"; fi ;;
        http)  url="http://$host:$port$path"
               if [ "$where" = ns ]; then http_code in_client curl -sS -m 6 -o /dev/null -w '%{http_code}' $CURL_OPTS "$url"
               else http_code curl -sS -m 6 -o /dev/null -w '%{http_code}' ${src:+--interface "$src"} $CURL_OPTS "$url"; fi ;;
        https) url="https://$host:$port$path"
               http_code in_client curl -sS -k -m 6 -o /dev/null -w '%{http_code}' $CURL_OPTS "$url" ;;
        route) in_client ip route get "$H_NET" 2>/dev/null | grep -q ' dev wgc' && echo OK || echo FALLA ;;
        dns)   [ -n "$(in_client getent hosts example.com 2>/dev/null)" ] && echo OK || echo FALLA ;;
        hs)    local pub hs
               pub="$(cat "$KEYS_DIR/${dest%%-*}.public.key" 2>/dev/null)"
               hs="$(wg show "${WG_IFACE:-wg0}" latest-handshakes 2>/dev/null | awk -v k="$pub" '$1==k{print $2}')"
               [ -n "$pub" ] && [ "${hs:-0}" -gt 0 ] && [ $(( $(date +%s) - hs )) -lt 300 ] && echo OK || echo FALLA ;;
        *)     echo "?" ;;
    esac
}

PASS=0; FAIL=0; SKIP=0
run_cases() {  # lee: id | dónde | tipo | destino | puerto | origen | esperado | decide | descripción
    local id where tipo dest port src exp decide desc got
    while IFS='|' read -r id where tipo dest port src exp decide desc; do
        id="$(trim "$id")"; [ -n "$id" ] || continue
        where="$(trim "$where")"; tipo="$(trim "$tipo")"; dest="$(trim "$dest")"; port="$(trim "$port")"
        src="$(trim "$src")"; exp="$(trim "$exp")"; decide="$(trim "$decide")"; desc="$(trim "$desc")"
        [ "$src" = "-" ] && src=""
        if [ "$SKIP_R1" -eq 1 ] && [[ "$decide" == *R1* ]]; then
            emit "$(printf 'SKIP  %-4s %-62s [%s: lo decide R1]' "$id" "$desc" "$decide")"; SKIP=$((SKIP+1)); continue
        fi
        got="$(probe "$where" "$tipo" "$dest" "$port" "$src")"
        if [ "$got" = "$exp" ]; then
            emit "$(printf 'PASS  %-4s %-62s [%s -> %s]' "$id" "$desc" "$decide" "$got")"; PASS=$((PASS+1))
        else
            emit "$(printf 'FAIL  %-4s %-62s [%s] esperado=%s real=%s' "$id" "$desc" "$decide" "$exp" "$got")"; FAIL=$((FAIL+1))
        fi
    done
}

# ---- tablas de casos ---------------------------------------------------------------------
cases_common() { cat <<EOF
I1 | host | hs    | $PEER | - | - | OK  | E4 | Handshake de $PEER visto en wg0 del servidor
I2 | ns   | ping  | $GW | - | - | OK  | E4 | El cliente alcanza la dirección de wg0 del servidor ($GW)
I3 | ns   | route | $H_NET | - | - | OK  | E4 | Full Tunnel: la ruta a Internet sale por el túnel
I4 | ns   | dns   | example.com | - | - | OK | E4 | DNS por el túnel (8.8.8.8 del perfil)
I5 | ns   | http  | $H_WEB01/ | 8081 | - | 200 | E4 | VPN -> WEB01 de la DMZ (no pasa por E5, se queda en E4)
I6 | ns   | tcp   | $H_NET | 443 | - | OK | E5 | Salida a Internet por el túnel hasta E5 y E3 (TCP/443)
EOF
}
cases_admin() { cat <<EOF
A1 | ns | ping  | $H_ADMIN | -  | - | OK        | E5 | VPN-ADMIN -> VLAN ADMIN (ping)
A2 | ns | tcp   | $H_USER  | 22 | - | OK        | E5 | VPN-ADMIN -> VLAN USERS (SSH)
A3 | ns | ping  | $H_ZBX   | -  | - | OK        | E5 | VPN-ADMIN -> Zabbix (ping)
A4 | ns | http  | $H_INTRA/ | 80 | - | 200      | E5 | VPN-ADMIN -> Intranet HTTP
A5 | ns | tcp   | $H_SW    | 22 | - | OK        | E5 | VPN-ADMIN -> GESTIÓN (SSH de SW-CORE01)
A6 | ns | http  | $H_ZBX/zabbix/ | 80 | - | 000 | R1 | VPN-ADMIN -> web de Zabbix: solo la VLAN ADMIN
EOF
}
cases_users() { cat <<EOF
U1 | ns | ping  | $H_USER  | -   | - | OK        | E5 | VPN-USERS -> VLAN USERS (ping)
U2 | ns | http  | $H_INTRA/ | 80  | - | 200      | E5 | VPN-USERS -> Intranet HTTP (servicio autorizado)
U3 | ns | https | $H_INTRA/ | 443 | - | 200      | E5 | VPN-USERS -> Intranet HTTPS (servicio autorizado)
U4 | ns | tcp   | $H_INTRA | 22  | - | BLOQUEADO | E5 | VPN-USERS -> SSH de la Intranet: fuera de los servicios autorizados
U5 | ns | ping  | $H_INTRA | -   | - | BLOQUEADO | E5 | VPN-USERS -> ping a la Intranet: solo 80 y 443
U6 | ns | ping  | $H_ADMIN | -   | - | BLOQUEADO | E5 | VPN-USERS -> VLAN ADMIN: denegado (log E5-DENY-VPNUSERS2ADMIN)
U7 | ns | tcp   | $H_SW    | 22  | - | BLOQUEADO | E5 | VPN-USERS -> GESTIÓN: denegado
U8 | ns | http  | $H_ZBX/zabbix/ | 80 | - | 000 | E5 | VPN-USERS -> web de Zabbix: denegado
EOF
}
cases_spoof() { cat <<EOF
S1 | ns | ping | $H_ADMIN | - | - | BLOQUEADO | E4 | Suplantación: $PEER con la IP de un admin llega a la VLAN ADMIN
S2 | ns | ping | $GW_ADMIN | - | - | BLOQUEADO | E4 | Suplantación: wg0 descarta el paquete (IP fuera de los AllowedIPs del peer)
EOF
}
cases_dmz() { cat <<EOF
D1 | host | http | $H_WEB01/ | 8081 | -         | 200       | E4 | WEB01 responde en la DMZ (local)
D2 | host | tcp  | $H_USER   | 22   | $H_WEB01  | BLOQUEADO | E5 | DMZ -> LAN (VLAN USERS :22): denegado (log E5-DENY-DMZ2LAN)
D3 | host | ping | $H_ADMIN  | -    | $H_WEB01  | BLOQUEADO | E5 | DMZ -> LAN (VLAN ADMIN, ping): denegado
D4 | host | tcp  | $H_INTRA  | 80   | $H_WEB01  | BLOQUEADO | E5 | DMZ -> Intranet: denegado
D5 | host | tcp  | $H_NET    | 443  | $H_WEB01  | OK        | E5 | DMZ -> Internet por HTTPS: permitido (salida de ngrok)
D6 | host | tcp  | $H_NET    | 80   | $H_WEB01  | BLOQUEADO | E5 | DMZ -> Internet por HTTP: denegado (el 80 es solo del host E4)
D7 | host | tcp  | $H_NET    | 80   | 192.168.83.2 | OK     | E5 | Host E4 -> Internet por HTTP: permitido (CRL de ngrok)
D8 | host | tcp  | $H_ZBX    | 10051 | 192.168.83.2 | OK    | E5 | Host E4 -> Zabbix 10051: permitido (agente)
D9 | host | tcp  | $H_ZBX    | 10051 | $H_WEB01  | BLOQUEADO | E5 | WEB01 -> Zabbix: denegado
EOF
}

manual_notes() { cat <<EOF

Pruebas que necesitan otros nodos (hacerlas a mano y guardar la captura):
  D-a  Internet -> WEB01 directo. Desde E3: nc -zv -w4 $H_WEB01 8081   -> sin respuesta
       Evidencia en E5: sudo journalctl -k | grep E5-DENY-INET2DMZ
  D-b  LAN -> WEB01: curl -m6 -o /dev/null -w '%{http_code}\n' http://$H_WEB01:8081/ desde PC-ADMIN01 y PC-USER01 -> 200
       PC-USER01: nc -zv -w4 $H_WEB01 22 -> sin respuesta; PC-MGMT01 -> sin respuesta (lo decide R1)
  D-c  ngrok: abrir la URL pública desde un teléfono con datos móviles -> página de WEB01
  V-a  Primera pasada: desde E3, echo x | nc -u -w1 192.168.83.2 51821 -> no llega a enp1s0
       (E5 solo abre UDP/51820). En E4: sudo tcpdump -ni enp1s0 udp port 51820
  V-b  Cliente real (teléfono) conectado a la red del ISP1: handshake y las páginas permitidas
  V-c  Balanceo con la VPN (ISP2 activo): http://api.ipify.org desde admin1, varias veces -> alterna dos IPs
  Logs que cierran la evidencia:
       E5: sudo journalctl -k | grep -E 'E5-(DENY|ACCEPT)'
       R1: sudo tail -20 /var/log/xelaju/acl-lan.log ; sudo nft list chain inet xelaju desde_perimetro
EOF
}

# ---- ejecución -----------------------------------------------------------------------------
emit "# Matriz de pruebas E4 - $(date '+%F %T') - objetivo: $TARGET - host: $(hostname)"
emit "# resultados guardados en: $OUT_FILE"

if [ "$TARGET" = dmz ]; then
    emit "## DMZ (origen: este equipo, con la dirección de WEB01 o del host E4)"
    run_cases < <(cases_dmz)
else
    PEER="$TARGET"
    case "$PEER" in admin*) KIND=admin ;; *) KIND=users ;; esac
    ADDR="$(sed -n 's/^Address *= *//p' "$KEYS_DIR/$PEER.conf" 2>/dev/null | head -1)"
    [ -n "$ADDR" ] || die "no existe el perfil $KEYS_DIR/$PEER.conf (gen_peers.sh --endpoint HOST:PUERTO --apply)"
    GW="${ADDR%.*}.1"; GW_ADMIN="10.200.10.1"
    cleanup() { [ "$KEEP" -eq 1 ] || "$CLIENT" down >/dev/null 2>&1; }
    trap cleanup EXIT
    "$CLIENT" down >/dev/null 2>&1
    "$CLIENT" up "$PEER" || die "no se pudo levantar el cliente $PEER"
    emit "## $PEER ($([ $KIND = admin ] && echo VPN-ADMIN || echo VPN-USERS), ${ADDR%%/*})"
    emit "-- Estado del túnel y salida"
    run_cases < <(cases_common)
    emit "-- Políticas de acceso"
    if [ $KIND = admin ]; then run_cases < <(cases_admin); else run_cases < <(cases_users); fi
    if [ $KIND = users ] && [ "$SPOOF" -eq 1 ]; then
        emit "-- Anti-suplantación (AllowedIPs): mismo peer, dirección de origen de VPN-ADMIN"
        "$CLIENT" down >/dev/null 2>&1
        if "$CLIENT" up "$PEER" --as-ip 10.200.10.10 >/dev/null 2>&1; then
            run_cases < <(cases_spoof)
        else
            emit "FAIL  S0   no se pudo levantar el cliente con --as-ip"; FAIL=$((FAIL+1))
        fi
    fi
fi

emit ""
emit "RESULTADO: $PASS PASS, $FAIL FAIL, $SKIP SKIP"
manual_notes | tee -a "$OUT_FILE" >/dev/null
manual_notes
if [ -n "${SUDO_USER:-}" ]; then chown -R "$SUDO_USER" "$OUT_DIR" 2>/dev/null || true; fi
echo "Guardado en $OUT_FILE"
[ "$FAIL" -eq 0 ]
