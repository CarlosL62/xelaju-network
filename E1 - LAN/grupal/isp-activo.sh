#!/bin/bash
# =============================================================================
# grupal/isp-activo.sh - por cual ISP del Multi-WAN (E3) sale el trafico de la LAN
#
#   sudo /mnt/proyecto/grupal/isp-activo.sh [-i seg] [-n ciclos] [-l registro]
#
# Se ejecuta DENTRO de R1-LAN, en modo grupal. Cada pocos segundos muestra una
# tabla y agrega una linea al registro con el ISP por el que sale cada clase de
# trafico (VLAN de origen + protocolo/puerto). ISP1 es la tarjeta Wi-Fi de E3
# e ISP2 el celular que comparte Internet por USB.
#
# Como lo averigua sin entrar a E3
#   E3 elige el ISP por conexion: segun su policies.txt o, si ninguna politica
#   coincide, al azar entre los dos (balanceo). Por cada clase se envia un
#   paquete cuyo TTL se agota justo en el salto siguiente a E3; el router que
#   avisa de que el paquete caduco es la puerta de enlace del ISP por el que
#   E3 lo saco. Es un traceroute de un solo salto, por TCP 443 o UDP 53, que
#   el firewall de E5 si deja pasar (con ping no se puede).
#   Ademas abre una conexion real de esa clase (columna EXTREMO): OK si va y
#   vuelve, FALLA si no.
#
# Como sabe cual puerta es ISP1 y cual ISP2
#   Esas direcciones las reparten los ISP (la del celular cambia al
#   reconectarlo) y son de E3: no estan en core/. Se aprenden en cada ciclo de
#   dos clases de referencia cuya salida es fija en policies.txt de E3
#   (REF_ISP1 y REF_ISP2, mas abajo; pruebas/consistencia.py avisa si E3 las
#   cambia). Si las dos referencias salen por la misma puerta, uno de los ISP
#   esta caido y E3 paso todo al otro (failover). Para fijarlas a mano con los
#   datos que de E3 (alli: ip route show table 100 y table 200):
#       sudo XJ_GW_ISP1=<ip> XJ_GW_ISP2=<ip> /mnt/proyecto/grupal/isp-activo.sh
#
# Limites
#   - El HTTP (puerto 80) no se puede seguir asi: lo intercepta Squid en E2 y
#     sale hacia Internet con la direccion de E2, no con la de la LAN.
#   - En las clases con balanceo, la sonda y la conexion de EXTREMO son
#     conexiones distintas: cada una puede salir por un ISP diferente.
#   - Los routers de los ISP limitan los avisos ICMP (uno por segundo tras una
#     rafaga corta): por eso va una sola sonda por clase, con pausas.
#
# Opciones
#   -i <seg>      segundos entre ciclos (10)
#   -n <ciclos>   termina tras ese numero de ciclos (0 = hasta Ctrl+C)
#   -l <archivo>  registro; "-" para no registrar. Por omision
#                 /mnt/evidencias/consola/isp-activo-AAAAMMDD.log, que en el
#                 host es evidencias/consola/
#
# Desde el host, sin abrir la consola de R1:
#   una lectura       ./lab/lab.sh exec r1-lan '/mnt/proyecto/grupal/isp-activo.sh -n 1'
#   en segundo plano  ./lab/lab.sh exec r1-lan 'setsid nohup /mnt/proyecto/grupal/isp-activo.sh >/dev/null 2>&1 &'
#   seguirlo          tail -f evidencias/consola/isp-activo-*.log
#   detenerlo         ./lab/lab.sh exec r1-lan "pkill -f '[i]sp-activo.sh'"
# =============================================================================
set -u
export LC_ALL=C
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# ---- Datos del grupo -----------------------------------------------------------
IP_E3="192.168.81.1"        # core/ADDRESSING.yaml, link_e3_e5.e3_ip
DESTINO_TCP="1.1.1.1"       # los DNS publicos del proyecto (xj_resolv). Las sondas
DESTINO_UDP="8.8.8.8"       # caducan antes de llegar: solo marcan el camino

# ---- Clases de trafico -----------------------------------------------------------
# nombre, origen (la IP de R1 en esa VLAN: E3 decide por la red de origen),
# protocolo y puerto
CLASES=(
    "ADMIN      192.168.10.1 tcp 443"
    "ADMIN      192.168.10.1 udp 53"
    "USUARIOS   192.168.20.1 tcp 443"
    "USUARIOS   192.168.20.1 udp 53"
    "SERVIDORES 192.168.30.1 tcp 443"
    "SERVIDORES 192.168.30.1 udp 53"
    "GESTION    192.168.40.1 tcp 443"
    "GESTION    192.168.40.1 udp 53"
)

# Clases de referencia: su salida es fija en policies.txt de E3
#   192.168.10.0/24, [443], TCP, ISP1        192.168.30.0/24, [443], TCP, ISP2
REF_ISP1="192.168.10.1 tcp 443"
REF_ISP2="192.168.30.1 tcp 443"

INTERVALO=10
CICLOS=0
REGISTRO=""
VENTANA=10                              # ciclos que resume la columna ULTIMOS
PAUSA=0.3                               # entre clases, por el limite de ICMP de los ISP
MEMORIA=/run/xelaju-isp-activo.estado   # ultimas puertas aprendidas (se pierde al reiniciar)

uso() { sed -n '3,51p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-1}"; }

while getopts "i:n:l:h" opcion; do
    case "$opcion" in
        i) INTERVALO="$OPTARG" ;;
        n) CICLOS="$OPTARG" ;;
        l) REGISTRO="$OPTARG" ;;
        h) uso 0 ;;
        *) uso 1 ;;
    esac
done
case "$INTERVALO$CICLOS" in *[!0-9]*|"") echo "isp-activo.sh: -i y -n llevan un numero entero" >&2; exit 2 ;; esac

if [ "$(id -u)" -ne 0 ]; then echo "isp-activo.sh: ejecutar como root (sudo): el traceroute por TCP lo necesita" >&2; exit 2; fi
for orden in traceroute nc dig; do
    command -v "$orden" >/dev/null || { echo "isp-activo.sh: falta la orden '$orden'" >&2; exit 2; }
done

# Solo se sondean las clases cuyo origen es una direccion de este equipo
locales=" $(ip -4 -o addr show | awk '{ sub(/\/.*/, "", $4); printf "%s ", $4 }')"
activas=()
for c in "${CLASES[@]}"; do
    read -r _ origen _ <<< "$c"
    case "$locales" in *" $origen "*) activas+=("$c") ;; esac
done
if [ "${#activas[@]}" -eq 0 ]; then
    echo "isp-activo.sh: ningun origen de CLASES es una direccion de este equipo: se ejecuta dentro de R1-LAN" >&2
    exit 2
fi
CLASES=("${activas[@]}")

if [ -z "$REGISTRO" ]; then
    if [ -d /mnt/evidencias/consola ] && [ -w /mnt/evidencias/consola ]; then
        REGISTRO="/mnt/evidencias/consola/isp-activo-$(date +%Y%m%d).log"
    else
        REGISTRO="/var/log/xelaju/isp-activo.log"
    fi
fi
[ "$REGISTRO" = "-" ] && REGISTRO=""

# ---- Puertas de enlace de cada ISP -------------------------------------------------
GW_ISP1="${XJ_GW_ISP1:-}"
GW_ISP2="${XJ_GW_ISP2:-}"
FIJAS=0
if [ -n "$GW_ISP1" ] && [ -n "$GW_ISP2" ]; then
    FIJAS=1
elif [ -r "$MEMORIA" ]; then
    read -r GW_ISP1 GW_ISP2 < "$MEMORIA" || true
fi

ahora() { date '+%F %T'; }

registrar() {       # agrega una linea con fecha al registro, si lo hay
    if [ -n "$REGISTRO" ]; then printf '%s %s\n' "$(ahora)" "$*" >> "$REGISTRO"; fi
}

evento() {          # algo que cambio: a pantalla y al registro
    printf '  >> %s\n' "$*"
    registrar "EVENTO $*"
}

# ---- Sondas ----------------------------------------------------------------------
# salto_de_e3 <origen>: numero del salto en el que responde E3 (vacio si no aparece)
salto_de_e3() {
    traceroute -T -p 443 -n -q 1 -w 2 -m 8 -s "$1" "$DESTINO_TCP" 2>/dev/null |
        awk -v e3="$IP_E3" '$2 == e3 { print $1; exit }'
}

# sonda_salida <origen> <protocolo> <puerto>: IP del router que responde en el
# salto siguiente a E3 (la puerta de enlace del ISP elegido); vacio si nadie
sonda_salida() {
    local metodo destino
    case "$2" in
        tcp) metodo=-T; destino="$DESTINO_TCP" ;;
        *)   metodo=-U; destino="$DESTINO_UDP" ;;
    esac
    traceroute "$metodo" -p "$3" -n -q 1 -w 1 -f "$SALTO_ISP" -m "$SALTO_ISP" -s "$1" "$destino" 2>/dev/null |
        awk -v t="$SALTO_ISP" '$1 == t && $2 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ { print $2; exit }'
}

# sonda_extremo <origen> <protocolo> <puerto>: una conexion real de esa clase.
# OK si va y vuelve, FALLA si no, "-" si no hay prueba para ese protocolo/puerto
sonda_extremo() {
    case "$2/$3" in
        tcp/*)
            if nc -z -w 2 -s "$1" "$DESTINO_TCP" "$3" >/dev/null 2>&1; then echo OK; else echo FALLA; fi ;;
        udp/53)
            if dig -b "$1" +time=2 +tries=1 +short @"$DESTINO_UDP" example.com A 2>/dev/null |
                    grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then echo OK; else echo FALLA; fi ;;
        *)  echo - ;;
    esac
}

etiqueta() {        # etiqueta <puerta>: ISP1, ISP2, ISP?, SIN-RUTA (contesta E3) o SIN-RESP
    if [ -z "$1" ]; then echo SIN-RESP
    elif [ "$1" = "$IP_E3" ]; then echo SIN-RUTA
    elif [ "$1" = "$GW_ISP1" ]; then echo ISP1
    elif [ "$1" = "$GW_ISP2" ]; then echo ISP2
    else echo "ISP?"; fi
}

# ---- Un ciclo ----------------------------------------------------------------------
declare -A PUERTA EXTREMO HISTORIA
SALTO_ISP=""
ESTADO="" ; DETALLE=""

medir() {
    local c nombre origen proto puerto clave gw ext
    for c in "${CLASES[@]}"; do
        read -r nombre origen proto puerto <<< "$c"
        clave="$origen $proto $puerto"
        gw="$(sonda_salida "$origen" "$proto" "$puerto")"
        ext="$(sonda_extremo "$origen" "$proto" "$puerto")"
        # Hay trafico pero nadie aviso: el router del ISP limito el ICMP. Un reintento
        if [ -z "$gw" ] && [ "$ext" != FALLA ]; then
            sleep 1
            gw="$(sonda_salida "$origen" "$proto" "$puerto")"
        fi
        PUERTA[$clave]="$gw"
        EXTREMO[$clave]="$ext"
        sleep "$PAUSA"
    done
}

# Aprende las puertas de las dos referencias y decide el estado general
evaluar() {
    local r1="${PUERTA[$REF_ISP1]:-}" r2="${PUERTA[$REF_ISP2]:-}" anterior="$ESTADO"
    if [ "$FIJAS" -eq 0 ] && [ -n "$r1" ] && [ -n "$r2" ] && [ "$r1" != "$r2" ] \
            && [ "$r1" != "$IP_E3" ] && [ "$r2" != "$IP_E3" ] \
            && { [ "$r1" != "$GW_ISP1" ] || [ "$r2" != "$GW_ISP2" ]; }; then
        GW_ISP1="$r1"; GW_ISP2="$r2"
        printf '%s %s\n' "$GW_ISP1" "$GW_ISP2" > "$MEMORIA" 2>/dev/null || true
        evento "puertas aprendidas de las referencias: ISP1=$GW_ISP1 ISP2=$GW_ISP2"
    fi

    if [ -z "$r1" ] && [ -z "$r2" ]; then
        ESTADO="SIN-RESPUESTA"; DETALLE="ninguna de las dos referencias obtuvo respuesta"
    elif [ -z "$r1" ] || [ -z "$r2" ]; then
        ESTADO="PARCIAL"; DETALLE="una de las dos referencias no obtuvo respuesta"
    elif [ "$r1" != "$r2" ] && { [ "$r1" = "$IP_E3" ] || [ "$r2" = "$IP_E3" ]; }; then
        # Visto en el failover real: una referencia ya sale y para la otra E3 aun no tiene ruta
        ESTADO="PARCIAL"; DETALLE="E3 contesta que no tiene ruta para una de las dos referencias"
    elif [ "$r1" != "$r2" ]; then
        ESTADO="NORMAL"; DETALLE="los dos ISP activos"
    else
        case "$(etiqueta "$r1")" in
            ISP1)     ESTADO="SOLO-ISP1"; DETALLE="lo que debia salir por ISP2 sale por ISP1: ISP2 caido (failover de E3)" ;;
            ISP2)     ESTADO="SOLO-ISP2"; DETALLE="lo que debia salir por ISP1 sale por ISP2: ISP1 caido (failover de E3)" ;;
            SIN-RUTA) ESTADO="SIN-SALIDA"; DETALLE="E3 contesta que no tiene ruta hacia Internet" ;;
            *)        ESTADO="UN-SOLO-ISP"; DETALLE="todo sale por $r1 y no se sabe cual ISP es: indicar XJ_GW_ISP1 y XJ_GW_ISP2" ;;
        esac
    fi
    if [ -n "$anterior" ] && [ "$anterior" != "$ESTADO" ]; then evento "estado $anterior -> $ESTADO ($DETALLE)"; fi
}

mostrar() {         # mostrar <numero de ciclo>: tabla en pantalla y una linea en el registro
    local c nombre origen proto puerto clave gw et e n1 n2 nx linea=""
    if [ -t 1 ]; then printf '\033[H\033[2J'; fi
    printf 'XelajuNetwork - ISP en uso (Multi-WAN de E3)    %s    ciclo %s\n' "$(ahora)" "$1"
    printf 'Estado: %s - %s\n' "$ESTADO" "$DETALLE"
    printf 'ISP1 (Wi-Fi de E3) = %s    ISP2 (celular) = %s%s\n\n' "${GW_ISP1:-sin aprender}" "${GW_ISP2:-sin aprender}" \
        "$([ "$FIJAS" -eq 1 ] && echo '    (fijadas a mano)')"
    printf '%-11s %-8s %-9s %-16s %-8s %s\n' ORIGEN TRAFICO ISP "PUERTA DE SALIDA" EXTREMO "ULTIMOS $VENTANA (ISP1/ISP2/otro)"
    for c in "${CLASES[@]}"; do
        read -r nombre origen proto puerto <<< "$c"
        clave="$origen $proto $puerto"
        gw="${PUERTA[$clave]}"
        et="$(etiqueta "$gw")"
        # shellcheck disable=SC2086  # la historia es una lista de palabras
        set -- ${HISTORIA[$clave]:-} "$et"
        while [ $# -gt "$VENTANA" ]; do shift; done
        HISTORIA[$clave]="$*"
        n1=0; n2=0; nx=0
        for e in "$@"; do
            case "$e" in ISP1) n1=$((n1 + 1)) ;; ISP2) n2=$((n2 + 1)) ;; *) nx=$((nx + 1)) ;; esac
        done
        printf '%-11s %-8s %-9s %-16s %-8s %s\n' "$nombre" "$proto/$puerto" "$et" "${gw:--}" "${EXTREMO[$clave]}" "$n1/$n2/$nx"
        # En el registro, la puerta solo se anota cuando no se sabe de que ISP es
        if [ "$et" = "ISP?" ]; then et="ISP?($gw)"; fi
        linea="$linea $nombre/$proto$puerto=$et,${EXTREMO[$clave]}"
    done
    if [ -n "$REGISTRO" ]; then printf '\nRegistro: %s\n' "$REGISTRO"; fi
    registrar "$ESTADO isp1=${GW_ISP1:--} isp2=${GW_ISP2:--} |$linea"
}

terminar() { registrar "FIN"; echo; exit 0; }
trap terminar INT TERM

# ---- Bucle principal -----------------------------------------------------------------
read -r _ primer_origen _ <<< "${CLASES[0]}"
if [ -n "$REGISTRO" ] && ! : >> "$REGISTRO" 2>/dev/null; then
    echo "isp-activo.sh: no se puede escribir en $REGISTRO: sigue sin registro" >&2
    REGISTRO=""
fi
registrar "INICIO intervalo=${INTERVALO}s clases=${#CLASES[@]} ref_isp1='$REF_ISP1' ref_isp2='$REF_ISP2'"

numero=0
while :; do
    inicio=$SECONDS
    numero=$((numero + 1))
    # El salto de E3 se busca al empezar y cada vez que un ciclo se queda sin respuestas
    if [ -z "$SALTO_ISP" ]; then
        salto="$(salto_de_e3 "$primer_origen")"
        if [ -n "$salto" ]; then SALTO_ISP=$((salto + 1)); fi
    fi
    if [ -z "$SALTO_ISP" ]; then
        echo "$(ahora)  E3 ($IP_E3) no aparece en el camino hacia Internet: R1 en modo grupal? E2 y E5 encendidos?"
        registrar "SIN-CAMINO E3 ($IP_E3) no aparece en el traceroute TCP 443 desde $primer_origen"
    else
        medir
        evaluar
        mostrar "$numero"
        if [ "$ESTADO" = "SIN-RESPUESTA" ]; then SALTO_ISP=""; fi
    fi
    if [ "$CICLOS" -gt 0 ] && [ "$numero" -ge "$CICLOS" ]; then break; fi
    resto=$((INTERVALO - (SECONDS - inicio)))
    # En segundo plano y con wait: asi una senal (pkill) corta la espera al instante
    sleep "$((resto > 1 ? resto : 1))" &
    wait $!
done
registrar "FIN"
