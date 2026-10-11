#!/bin/bash
# =============================================================================
# pruebas/probar.sh - ejecuta los casos de pruebas/matriz.conf de un perfil
#
#   sudo /mnt/proyecto/pruebas/probar.sh <perfil>      (dentro del equipo)
#   ./lab/lab.sh probar [perfil...]                    (desde el host, todos)
#
# Por cada caso compara lo OBTENIDO con lo ESPERADO y marca PASS o FAIL.
# Deja una copia del resultado en /mnt/evidencias/pruebas/ (carpeta compartida
# con el host). Termina con codigo 0 si no hubo ningun FAIL.
#
# Los perfiles users (caso 'dhcp renovar') e intruso reconfiguran la interfaz:
# ejecutarlos por consola o con lab.sh, no por SSH.
# =============================================================================
set -u
export LC_ALL=C
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MATRIZ="${XJ_MATRIZ:-$AQUI/matriz.conf}"
INTERFAZ="${XJ_IF:-lan0}"
URL_INTERNET="${XJ_URL_INTERNET:-http://deb.debian.org/debian/dists/trixie/Release}"
DIR_EVID="${XJ_EVIDENCIAS:-/mnt/evidencias/pruebas}"
EQUIPO="${XJ_EQUIPO:-$(hostname)}"
PERFIL="${1:-}"

if [ -z "$PERFIL" ]; then
    echo "uso: probar.sh <perfil>     perfiles: $(sed -e 's/#.*//' "$MATRIZ" | awk '$1 == "perfil" { printf "%s ", $2 }')" >&2
    exit 2
fi
if [ "$(id -u)" -ne 0 ]; then echo "probar.sh: ejecutar como root (sudo)" >&2; exit 2; fi

# ---- Sondas: cada una imprime UNA palabra con lo obtenido --------------------
ip_actual() { ip -4 -o addr show dev "$INTERFAZ" 2>/dev/null | awk '{ sub(/\/.*/, "", $4); print $4; exit }'; }

sonda_ip() { local a; a="$(ip_actual)"; echo "${a:-SIN-IP}"; }

sonda_ping() {
    if ping -c 2 -W 2 -q "$1" >/dev/null 2>&1; then echo OK; else echo BLOQUEADO; fi
}

sonda_tcp() {       # 0 = conecto, 124 = sin respuesta (timeout), otro = rechazo
    timeout 4 bash -c "exec 3<>/dev/tcp/$1/$2" >/dev/null 2>&1
    case $? in
        0)   echo OK ;;
        124) echo BLOQUEADO ;;
        *)   echo RECHAZADO ;;
    esac
}

sonda_http() {      # sonda_http <http|https> <destino>
    local codigo rc
    codigo="$(curl -s -k -o /dev/null -m 6 -w '%{http_code}' "$1://$2" 2>/dev/null)"; rc=$?
    case $rc in
        0)  echo "$codigo" ;;
        7)  echo RECHAZADO ;;
        *)  echo BLOQUEADO ;;       # 28 = tiempo agotado, 6 = sin DNS...
    esac
}

sonda_internet() {
    local codigo
    codigo="$(curl -s -o /dev/null -m 10 -w '%{http_code}' "$URL_INTERNET" 2>/dev/null)"
    case "$codigo" in
        2??|3??) echo OK ;;
        *)       echo BLOQUEADO ;;
    esac
}

sonda_dhcp() {
    # Sin cliente DHCP (o en el ensayo sin VMs) el caso se omite, no falla
    if [ "${XJ_SIN_DHCP:-}" = 1 ] || ! command -v dhclient >/dev/null; then echo OMITIDA; return; fi
    case "$1" in
        renovar)    # suelta la IP (DHCPRELEASE) y la vuelve a pedir desde cero (DORA completo)
            ifdown --force "$INTERFAZ" >/dev/null 2>&1
            ifup "$INTERFAZ" >/dev/null 2>&1
            sonda_ip
            ;;
        pedir)      # un solo intento de 10 s, con archivos propios para no dejar rastro
            local conf=/etc/dhcp/xelaju-prueba.conf pid=/run/dhclient.xelaju-prueba.pid
            local prestamos=/var/lib/dhcp/dhclient.xelaju-prueba.leases a
            printf 'timeout 10;\n' > "$conf"
            ip link set dev "$INTERFAZ" up
            if dhclient -1 -cf "$conf" -pf "$pid" -lf "$prestamos" "$INTERFAZ" >/dev/null 2>&1; then
                a="$(ip_actual)"; echo "IP-${a:-?}"
                dhclient -r -cf "$conf" -pf "$pid" -lf "$prestamos" "$INTERFAZ" >/dev/null 2>&1
            else
                echo SIN-OFERTA
            fi
            rm -f "$conf" "$pid" "$prestamos"
            ;;
        *)  echo ERROR ;;
    esac
}

sonda_estatica() {  # sonda_estatica <ip/prefijo> <puerta de enlace>
    ip addr flush dev "$INTERFAZ" 2>/dev/null
    if ip addr add "$1" dev "$INTERFAZ" && ip link set dev "$INTERFAZ" up \
            && ip route replace default via "$2" dev "$INTERFAZ"; then echo OK; else echo ERROR; fi
}

sonda_limpiar() {
    ip route flush dev "$INTERFAZ" 2>/dev/null
    ip addr flush dev "$INTERFAZ" 2>/dev/null
    echo OK
}

# ---- Ejecucion -----------------------------------------------------------------
correr() {
    local id tipo destino puerto esperado desc obtenido marca pasan=0 fallan=0 omitidas=0 que
    echo "=== Pruebas del perfil '$PERFIL' en $EQUIPO - $(date '+%F %T') ==="
    printf '%-5s %-5s %-14s %-14s %s\n' CASO RES. ESPERADO OBTENIDO PRUEBA
    # La matriz se lee por el descriptor 9 para que las sondas no consuman la entrada
    while IFS='|' read -r id tipo destino puerto esperado desc <&9; do
        case "$tipo" in
            ip)       obtenido="$(sonda_ip)";                        que="ip de $INTERFAZ" ;;
            ping)     obtenido="$(sonda_ping "$destino")";           que="ping $destino" ;;
            tcp)      obtenido="$(sonda_tcp "$destino" "$puerto")";  que="tcp $destino:$puerto" ;;
            http)     obtenido="$(sonda_http http "$destino")";      que="http://$destino" ;;
            https)    obtenido="$(sonda_http https "$destino")";     que="https://$destino" ;;
            internet) obtenido="$(sonda_internet)";                  que="internet" ;;
            dhcp)     obtenido="$(sonda_dhcp "$destino")";           que="dhcp $destino" ;;
            estatica) obtenido="$(sonda_estatica "$destino" "$puerto")"; que="ip a mano $destino" ;;
            limpiar)  obtenido="$(sonda_limpiar)";                   que="quitar ip a mano" ;;
            *)        obtenido=ERROR;                                que="tipo desconocido '$tipo'" ;;
        esac
        if [ "$obtenido" = OMITIDA ]; then marca="--"; omitidas=$((omitidas + 1))
        elif [ "$obtenido" = "$esperado" ]; then marca=PASS; pasan=$((pasan + 1))
        else marca=FAIL; fallan=$((fallan + 1)); fi
        printf '%-5s %-5s %-14s %-14s %s\n' "$id" "$marca" "$esperado" "$obtenido" "$que - $desc"
    done 9< <(sed -e 's/^[[:space:]]*#.*//' "$MATRIZ" | awk -F'|' -v p="$PERFIL" '
        NF >= 7 {
            for (i = 1; i <= NF; i++) gsub(/^[ \t]+|[ \t]+$/, "", $i)
            if ($2 == p) print $1 "|" $3 "|" $4 "|" $5 "|" $6 "|" $7
        }')
    echo "Resumen '$PERFIL': $((pasan + fallan + omitidas)) casos, $pasan PASS, $fallan FAIL, $omitidas omitidas"
    if [ $((pasan + fallan + omitidas)) -eq 0 ]; then echo "(no hay casos para el perfil '$PERFIL' en $MATRIZ)"; return 2; fi
    [ "$fallan" -eq 0 ]
}

salida="$(mktemp)"
correr | tee "$salida"
rc="${PIPESTATUS[0]}"
if mkdir -p "$DIR_EVID" 2>/dev/null && [ -w "$DIR_EVID" ]; then
    copia="$DIR_EVID/$PERFIL-$EQUIPO-$(date +%Y%m%d-%H%M%S).txt"
    cp "$salida" "$copia" && echo "Copia: $copia"
fi
rm -f "$salida"
exit "$rc"
