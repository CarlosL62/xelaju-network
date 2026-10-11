#!/bin/bash
# =============================================================================
# pruebas/simular-lan.sh - ensayo de la LAN completa SIN maquinas virtuales
#
# Arma en el host, sin root y en segundos, una copia de la red hecha con
# "network namespaces" de Linux: cada VM de lab/topologia.conf es un
# namespace y cada cable es un par veth con las mismas MAC. Sobre eso se
# aplican los archivos REALES del repositorio:
#   - switches:  nodos/_comun/switch/switch-aplicar con su switch.conf y puertos.conf
#   - R1-LAN:    /etc/network/interfaces, el modo elegido y las ACL de nftables
#   - ZBX-SRV01: su nftables.conf
# y se ejecuta pruebas/probar.sh con pruebas/matriz.conf en cada "equipo".
#
# Sirve para validar VLAN, enrutamiento y ACL antes de levantar las VMs.
# No simula: DHCP (no hay servidor ni cliente en el host), Zabbix ni systemd.
#
#   ./pruebas/simular-lan.sh              modo individual (NAT en R1)
#   ./pruebas/simular-lan.sh grupal       modo grupal (E2, E5, E3 y E4 simulados con dobles de prueba)
#   ./pruebas/simular-lan.sh -v [modo]    muestra todos los casos, no solo el resumen
#
# Requisitos del host: iproute2, nftables, python3, curl, openssl.
# =============================================================================
set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export LC_ALL=C

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ---- 1. Entrar en namespaces propios (usuario, red, montaje y procesos) ------
# -r  el usuario pasa a ser "root" solo dentro (puede crear interfaces y reglas)
# -n  red propia: nada de esto toca la red real del host
# -m  montajes propios, para tener un /run donde "ip netns" guarde los suyos
# --pid --fork --kill-child: al terminar el script mueren todos sus procesos
if [ "${XJ_DENTRO:-}" != 1 ]; then
    exec env XJ_DENTRO=1 unshare -r -n -m --pid --fork --kill-child --mount-proc "$0" "$@"
fi

DETALLE=0
if [ "${1:-}" = "-v" ]; then DETALLE=1; shift; fi
MODO="${1:-individual}"
case "$MODO" in individual|grupal) ;; *) echo "uso: simular-lan.sh [-v] [individual|grupal]" >&2; exit 2 ;; esac

TOPO="$REPO/lab/topologia.conf"
R1="$REPO/nodos/r1-lan/rootfs"
TMP="$(mktemp -d)"
SALIDA="$TMP/salida.txt"
INTERNET_IP=203.0.113.80            # "Internet" simulada (rango reservado para documentacion)
ISP_E3=198.51.100.1                 # (grupal) IP "publica" del doble de E3 hacia su ISP simulado
mount -t tmpfs tmpfs /run

topo() { sed -e 's/#.*//' "$TOPO"; }
en()   { local ns="$1"; shift; ip netns exec "$ns" "$@"; }
paso() { printf '\n== %s\n' "$*"; }

# ---- 2. Un namespace por VM y un par veth por cable --------------------------
paso "Topologia: $(topo | awk '$1=="vm"' | wc -l) equipos y $(topo | grep -c 'cable:' | awk '{print $1/2}') cables de lab/topologia.conf"
for vm in $(topo | awk '$1=="vm" {print $2}'); do
    ip netns add "$vm"
    en "$vm" ip link set lo up
done
# Cada cable aparece en dos lineas "nic": se emparejan y se crea el veth con sus MAC
topo | awk '$1=="nic" && $5 ~ /^cable:/ {
        c = $5
        if (c in vm) print vm[c], ifn[c], mac[c], $2, $3, $4
        else { vm[c] = $2; ifn[c] = $3; mac[c] = $4 }
    }' | while read -r vm_a if_a mac_a vm_b if_b mac_b; do
        ip link add "$if_a" address "$mac_a" netns "$vm_a" type veth peer name "$if_b" address "$mac_b" netns "$vm_b"
    done
# Puertos sin cable (SPAN y enlaces de salida no usados): interfaz "dummy"
topo | awk '$1=="nic" && $5 !~ /^cable:/ {print $2, $3, $4, $5}' | while read -r vm ifn mac con; do
    if [ "$MODO" = grupal ] && [ "${con%%:*}" = tap ]; then continue; fi       # los conecta el paso 6
    if [ "$MODO" = individual ] && [ "${con%%:*}" = nat ]; then continue; fi   # idem
    en "$vm" ip link add "$ifn" address "$mac" type dummy
done

# ---- 3. Switches: los scripts y archivos reales -------------------------------
paso "Switches (switch-aplicar con switch.conf y puertos.conf de cada uno)"
for sw in sw-core01 sw-acc01; do
    XJ_ETC="$REPO/nodos/$sw" en "$sw" "$REPO/nodos/_comun/switch/switch-aplicar" | sed 's/^/   /'
done

# ---- 4. Direcciones: se leen de los mismos archivos "interfaces" --------------
# aplicar_interfaces <namespace> <archivo>...: version minima de ifupdown
# (iface/address/gateway/up) para no depender de el en el host.
aplicar_interfaces() {
    local ns="$1"; shift
    awk '
        $1 == "iface"   { ifn = $2; if ($4 != "loopback") print "IFACE", ifn }
        $1 == "address" { print "ADDR", ifn, $2 }
        $1 == "gateway" { print "GW", ifn, $2 }
        $1 == "up"      { $1 = ""; gsub(/\$IFACE/, ifn); print "UP" $0 }
    ' "$@" | while read -r accion a b; do
        case "$accion" in
            IFACE)
                if [[ "$a" == *.* ]] && ! en "$ns" test -d "/sys/class/net/$a"; then
                    en "$ns" ip link add link "${a%.*}" name "$a" type vlan id "${a##*.}"
                fi
                en "$ns" ip link set dev "$a" up ;;
            ADDR) en "$ns" ip addr add "$b" dev "$a" ;;
            GW)   en "$ns" ip route replace default via "$b" dev "$a" ;;
            UP)   en "$ns" sh -c "$a $b" ;;
        esac
    done
}

paso "Direccionamiento (archivos interfaces de cada nodo; R1 en modo $MODO)"
# R1 se direcciona en el paso 6, cuando ya existen sus enlaces de salida
for vm in zbx-srv01 srv-intra01 pc-mgmt01 pc-admin01 pc-intruso; do
    f="$REPO/nodos/$vm/interfaces"; [ -f "$f" ] || f="$REPO/nodos/$vm/rootfs/etc/network/interfaces"
    aplicar_interfaces "$vm" "$f"
done
# Clientes DHCP: aqui no hay servidor; se les pone la IP que R1 les reservaria
topo | awk '$1=="ip" && $6=="dhcp" {print $2, $3, $4, $5}' | while read -r vm ifn dir gw; do
    en "$vm" ip link set dev "$ifn" up
    en "$vm" ip addr add "$dir" dev "$ifn"
    en "$vm" ip route replace default via "$gw"
done

# ---- 5. Servicios de mentira para que las pruebas tengan a que conectarse ------
cat > "$TMP/servicio.py" <<'PY'
"""Escucha en los puertos indicados: tcp=22,10050 http=80 https=443 cert=F clave=F log=F"""
import socket, ssl, sys, threading, time
arg = dict(a.split("=", 1) for a in sys.argv[1:])

def servir(puerto, modo):
    s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("0.0.0.0", puerto)); s.listen(32)
    ctx = None
    if modo == "https":
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx.load_cert_chain(arg["cert"], arg["clave"])
    while True:
        c, origen = s.accept()
        try:
            if "log" in arg:
                with open(arg["log"], "a") as f: f.write("%s %d\n" % (origen[0], puerto))
            if ctx: c = ctx.wrap_socket(c, server_side=True)
            if modo != "tcp":
                c.settimeout(2); c.recv(4096)
                c.sendall(b"HTTP/1.0 200 OK\r\nContent-Length: 3\r\nConnection: close\r\n\r\nok\n")
        except Exception:
            pass
        finally:
            c.close()

for modo in ("tcp", "http", "https"):
    for p in filter(None, arg.get(modo, "").split(",")):
        threading.Thread(target=servir, args=(int(p), modo), daemon=True).start()
while True: time.sleep(60)
PY
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=intranet \
    -keyout "$TMP/clave.pem" -out "$TMP/cert.pem" >/dev/null 2>&1
servicio() { local ns="$1"; shift; en "$ns" python3 "$TMP/servicio.py" "$@" & }

# ---- 6. R1: enlaces de salida, vecinos simulados, reenvio y ACL ----------------
vecino() {  # vecino <ns> <if de R1> <ip/prefijo del vecino>: namespace unido a un enlace de R1
    local ns="$1" ifr="$2" dir="$3" mac
    mac="$(topo | awk -v i="$ifr" '$1=="nic" && $2=="r1-lan" && $3==i {print $4}')"
    ip netns add "$ns"; en "$ns" ip link set lo up
    ip link add "$ifr" address "$mac" netns r1-lan type veth peer name eth0 netns "$ns"
    en "$ns" ip link set eth0 up; en "$ns" ip addr add "$dir" dev eth0
}
equipo() {  # equipo <ns>: crea el namespace si todavia no existe
    [ -e "/run/netns/$1" ] || { ip netns add "$1"; en "$1" ip link set lo up; }
}
enlace() {  # enlace <nsA> <ip/prefijo A> <nsB> <ip/prefijo B>: cable entre dos equipos simulados
    local a="$1" dir_a="$2" b="$3" dir_b="$4"
    equipo "$a"; equipo "$b"
    ip link add "a-$b" netns "$a" type veth peer name "a-$a" netns "$b"
    en "$a" ip link set "a-$b" up; en "$a" ip addr add "$dir_a" dev "a-$b"
    en "$b" ip link set "a-$a" up; en "$b" ip addr add "$dir_b" dev "a-$a"
}
rutas() {   # rutas <ns> <siguiente salto> <red>...: una ruta estatica por red (sin resumir)
    local ns="$1" salto="$2" red; shift 2
    for red in "$@"; do en "$ns" ip route replace "$red" via "$salto"; done
}

if [ "$MODO" = individual ]; then
    paso "Salida individual: 'internet' hace de NAT de QEMU (10.0.2.2) y de sitio web ($INTERNET_IP)"
    vecino internet tmp-nat 10.0.2.2/24
    en internet ip addr add "$INTERNET_IP/32" dev lo
    servicio internet http=80 log="$TMP/visitas.txt"
else
    # Dobles de prueba de los equipos de los companeros. Direcciones y rutas
    # son las de core/ADDRESSING.yaml (inter_node_links y routing_plan):
    #
    #   R1 --84.0/30-- E2 --82.0/30-- E5 --81.0/30-- E3 --(ISP simulado)-- internet
    #                                  |
    #                                  +--83.0/30-- E4 -- clientes VPN y WEB01 (DMZ)
    #
    # Lo unico REAL en este ensayo es R1 (y los switches y ZBX). Los dobles
    # solo reenvian; E5 ademas filtra con las reglas PROPUESTAS en el ADR-0002
    # y E3 hace el unico NAT del grupo. No son la configuracion de nadie.
    paso "Vecinos del modo grupal (dobles de prueba): E2 Squid, E5 firewall, E3 Multi-WAN, E4 VPN/DMZ"
    LAN_VLANS="192.168.10.0/24 192.168.20.0/24 192.168.30.0/24 192.168.40.0/24"
    VPN="10.200.10.0/24 10.200.20.0/24"
    DMZ="172.16.10.0/24"

    # E2 (Squid): 192.168.84.1 hacia R1 y 192.168.82.2 hacia E5; reenvia IP
    vecino e2 up-squid 192.168.84.1/30
    enlace e2 192.168.82.2/30 e5 192.168.82.1/30
    # E5 (firewall): 192.168.81.2 hacia E3 y 192.168.83.1 hacia E4
    enlace e5 192.168.81.2/30 e3 192.168.81.1/30
    enlace e5 192.168.83.1/30 e4 192.168.83.2/30
    # E3 (Multi-WAN): su "ISP" es otro namespace; alli vive el sitio de Internet
    enlace e3 "$ISP_E3/30" internet 198.51.100.2/30
    en internet ip addr add "$INTERNET_IP/32" dev lo
    # E4 (VPN/DMZ): wg0 tiene 10.200.10.1 y 10.200.20.1; la DMZ, 172.16.10.1.
    # Los clientes VPN y WEB01 son namespaces aparte para poder originar
    # trafico con su direccion (en el E4 real, WEB01 es una IP del mismo host).
    enlace e4 10.200.10.1/24 vpn-admin 10.200.10.10/24
    enlace e4 10.200.20.1/24 vpn-users 10.200.20.10/24
    enlace e4 172.16.10.1/24 web01     172.16.10.10/24
    for ns in e2 e5 e3 e4; do en "$ns" sysctl -qw net.ipv4.ip_forward=1; done

    # routing_plan de core/ADDRESSING.yaml, una ruta por prefijo
    en e2 ip route replace default via 192.168.82.1
    rutas e2 192.168.84.2 $LAN_VLANS
    en e5 ip route replace default via 192.168.81.1
    rutas e5 192.168.82.2 $LAN_VLANS
    rutas e5 192.168.83.2 $VPN $DMZ
    # (fuera del routing_plan actual) E5 necesita llegar al enlace E1-E2 para
    # devolver lo que origina el propio R1 con 192.168.84.2: propuesto en el PR de core/
    rutas e5 192.168.82.2 192.168.84.0/30
    en e4 ip route replace default via 192.168.83.1
    rutas e3 192.168.81.2 $LAN_VLANS $VPN $DMZ 192.168.82.0/30 192.168.83.0/30 192.168.84.0/30
    en e3 ip route replace default via 198.51.100.2
    en vpn-admin ip route replace default via 10.200.10.1
    en vpn-users ip route replace default via 10.200.20.1
    en web01     ip route replace default via 172.16.10.1

    # E3: unico NAT del grupo. Anota en un conjunto cada IP de origen que ve
    # ANTES de traducirla: asi se comprueba que las VLAN le llegan sin NAT.
    en e3 nft -f - <<EOF
table inet doble_e3 {
    set origenes { type ipv4_addr; flags dynamic; }
    chain reenvio {
        type filter hook forward priority filter; policy accept;
        oifname "a-internet" update @origenes { ip saddr }
    }
    chain nat_salida {
        type nat hook postrouting priority srcnat; policy accept;
        oifname "a-internet" masquerade
    }
}
EOF

    # E5: politica por omision drop y las reglas PROPUESTAS en el ADR-0002
    # (seccion "Proposals for Review"). La lista de servicios de la VLAN 30
    # para VPN-USERS y el permiso de monitoreo son lo que E1 pide a E5.
    en e5 nft -f - <<EOF
define LAN_VLANS = { 192.168.10.0/24, 192.168.20.0/24, 192.168.30.0/24, 192.168.40.0/24 }
table inet doble_e5 {
    chain reenvio {
        type filter hook forward priority filter; policy drop;
        ct state vmap { established : accept, related : accept, invalid : drop }
        # LAN -> Internet y LAN -> WEB01 de la DMZ (camino largo, ADR-0001)
        iifname "a-e2" ip saddr \$LAN_VLANS oifname "a-e3" accept
        iifname "a-e2" ip saddr \$LAN_VLANS ip daddr 172.16.10.10 tcp dport 8081 accept
        # Segunda pasada de la VPN: trafico ya descifrado que llega desde E4
        iifname "a-e4" ip saddr 10.200.10.0/24 ip daddr \$LAN_VLANS accept
        iifname "a-e4" ip saddr 10.200.20.0/24 ip daddr 192.168.20.0/24 accept
        iifname "a-e4" ip saddr 10.200.20.0/24 ip daddr 192.168.30.20 tcp dport { 80, 443 } accept
        # Monitoreo: agentes de E3 y E4 hacia el servidor Zabbix
        ip saddr { 192.168.81.1, 192.168.83.2 } ip daddr 192.168.30.10 tcp dport 10051 accept
        # Ping de prueba de rutas entre enlaces de transito
        ip saddr { 192.168.81.0/30, 192.168.83.0/30 } ip daddr 192.168.84.0/30 icmp type echo-request accept
        # VPN (tunel completo) y DMZ (ngrok) hacia Internet
        iifname "a-e4" oifname "a-e3" accept
    }
}
EOF

    servicio internet http=80 log="$TMP/visitas.txt"
    servicio web01 http=8081 tcp=22
fi

aplicar_interfaces r1-lan "$R1/etc/network/interfaces" "$R1/etc/network/modos/$MODO"
en r1-lan sysctl -q -p "$R1/etc/sysctl.d/90-xelaju-router.conf" 2>/dev/null || true
[ "$(en r1-lan sysctl -n net.ipv4.ip_forward)" = 1 ] || { echo "ERROR: no se pudo activar ip_forward"; exit 1; }

paso "ACL de R1 (nftables.conf + nftables.d, modo $MODO) y cortafuegos de ZBX"
mkdir -p "$TMP/nft"
cp -r "$R1/etc/nftables.conf" "$R1/etc/nftables.d" "$TMP/nft/"
cp "$TMP/nft/nftables.d/modos/$MODO.nft" "$TMP/nft/nftables.d/20-modo.nft"    # hace de enlace simbolico
sed -i "s|/etc/nftables.d|$TMP/nft/nftables.d|" "$TMP/nft/nftables.conf"
en r1-lan nft -f "$TMP/nft/nftables.conf"
en zbx-srv01 nft -f "$REPO/nodos/zbx-srv01/rootfs/etc/nftables.conf"
echo "   R1: $(en r1-lan nft list ruleset | grep -c 'counter') reglas con contador;  ZBX: $(en zbx-srv01 nft list ruleset | grep -c 'counter')"

servicio r1-lan      tcp=22,10050
servicio sw-core01   tcp=22,10050
servicio sw-acc01    tcp=22,10050
servicio zbx-srv01   http=80 tcp=22,10051
servicio srv-intra01 http=80 https=443 tcp=22 cert="$TMP/cert.pem" clave="$TMP/clave.pem"
for vm in pc-admin01 pc-user01 pc-user02 pc-mgmt01; do servicio "$vm" tcp=22; done
sleep 1

# ---- 7. La matriz de pruebas, con el mismo probar.sh de las VMs ----------------
TOTAL_PASS=0; TOTAL_FAIL=0; TOTAL_OMIT=0
correr_matriz() {   # correr_matriz <archivo de matriz>
    local matriz="$1" perfil vm linea
    while read -r perfil vm; do
        if ! ip netns list | grep -q "^$vm\b"; then continue; fi
        XJ_MATRIZ="$matriz" XJ_URL_INTERNET="http://$INTERNET_IP/" XJ_EVIDENCIAS=/nonexistent XJ_SIN_DHCP=1 \
            XJ_EQUIPO="$vm" en "$vm" "$REPO/pruebas/probar.sh" "$perfil" > "$TMP/perfil.txt" 2>&1 || true
        cat "$TMP/perfil.txt" >> "$SALIDA"
        linea="$(grep '^Resumen' "$TMP/perfil.txt" || echo "Resumen '$perfil': sin resultado")"
        if [ "$DETALLE" -eq 1 ]; then sed 's/^/   /' "$TMP/perfil.txt"; else echo "   $linea"; grep -E '^[A-Z0-9]+ +FAIL' "$TMP/perfil.txt" | sed 's/^/      /' || true; fi
        TOTAL_PASS=$((TOTAL_PASS + $(grep -c -E '^[A-Z0-9]+ +PASS' "$TMP/perfil.txt" || true)))
        TOTAL_FAIL=$((TOTAL_FAIL + $(grep -c -E '^[A-Z0-9]+ +FAIL' "$TMP/perfil.txt" || true)))
        TOTAL_OMIT=$((TOTAL_OMIT + $(grep -c -E '^[A-Z0-9]+ +-- ' "$TMP/perfil.txt" || true)))
    done < <(sed -e 's/#.*//' "$matriz" | awk '$1=="perfil" {print $2, $3}')
}

paso "Matriz de pruebas (pruebas/matriz.conf)"
correr_matriz "$REPO/pruebas/matriz.conf"
if [ "$MODO" = grupal ]; then
    paso "Matriz de la parte grupal (grupal/matriz-grupal.conf)"
    correr_matriz "$REPO/grupal/matriz-grupal.conf"
fi

# ---- 8. Comprobaciones propias del ensayo -------------------------------------
paso "Comprobaciones adicionales"
EXTRA_FAIL=0
comprobar() {   # comprobar <descripcion> <orden que debe terminar con 0>
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then echo "   PASS  $desc"; else echo "   FAIL  $desc"; EXTRA_FAIL=$((EXTRA_FAIL + 1)); fi
}
origen_visto() { grep -q "^$1 80\$" "$TMP/visitas.txt"; }
if [ "$MODO" = individual ]; then
    comprobar "NAT en modo individual: Internet ve a los clientes como 10.0.2.15 (R1)" origen_visto 10.0.2.15
    comprobar "NAT en modo individual: Internet NO ve direcciones 192.168.x.x" bash -c "! grep -q '^192\.168\.' '$TMP/visitas.txt'"
else
    visto_e3() {    # visto_e3 <ip>: el doble de E3 vio esa IP de origen antes de su NAT
        local s; s="$(en e3 nft list set inet doble_e3 origenes)"; grep -qw "$1" <<< "$s"
    }
    cuenta() {      # cuenta <texto de una regla de R1>: esa regla conto al menos un paquete
        local s; s="$(en r1-lan nft list table inet xelaju | grep -F -- "$1")"; grep -q -v 'packets 0 ' <<< "$s"
    }
    solo_e3() { [ "$(cut -d' ' -f1 "$TMP/visitas.txt" | sort -u)" = "$ISP_E3" ]; }
    sin_rutas_propias() { local s; s="$(en r1-lan ip route show)"; ! grep -qE '^(10\.200|172\.16)' <<< "$s"; }
    comprobar "Sin NAT en R1: el Multi-WAN ve la IP real de PC-USER01 (192.168.20.10)" visto_e3 192.168.20.10
    comprobar "Sin NAT en R1: el Multi-WAN ve la IP real de PC-ADMIN01 (192.168.10.50)" visto_e3 192.168.10.50
    comprobar "Sin NAT en R1: no existe cadena de NAT en R1" bash -c "! ip netns exec r1-lan nft list ruleset | grep -q 'type nat'"
    comprobar "NAT solo en E3: Internet ve una unica direccion, la del Multi-WAN ($ISP_E3)" solo_e3
    comprobar "Una sola salida: R1 no tiene rutas propias a VPN ni DMZ (las cubre la ruta por defecto)" sin_rutas_propias
    comprobar "ACL: la regla VPN->LAN de R1 conto las conexiones de los clientes VPN" cuenta 'ACL-ALLOW VPN->LAN'
    comprobar "ACL: R1 nego la web de Zabbix a un cliente VPN (PERIMETRO->ZBXWEB)" cuenta 'PERIMETRO->ZBXWEB'

    # Frontera E1/E5: que hace R1 POR SI SOLO si el firewall dejara pasar todo.
    # Se vacia el doble de E5 (queda como un router sin filtro) y se repiten
    # unas pruebas: lo que ahora se bloquee, lo bloquean las ACL de R1.
    en e5 nft flush ruleset
    llega() {       # llega <ns> <ping|tcp|http> <destino> [puerto]: exito si hubo respuesta
        case "$2" in
            ping) en "$1" ping -c 1 -W 2 -q "$3" ;;
            tcp)  en "$1" timeout 3 bash -c "exec 3<>/dev/tcp/$3/$4" ;;
            http) en "$1" curl -s -o /dev/null -m 4 "http://$3" ;;
        esac
    }
    no_llega() { ! llega "$@"; }
    comprobar "Sin E5, R1 sigue negando DMZ -> ADMIN (ping de WEB01 a PC-ADMIN01)" no_llega web01 ping 192.168.10.50
    comprobar "Sin E5, R1 sigue negando DMZ -> Intranet" no_llega web01 http 192.168.30.20/
    comprobar "Sin E5, R1 sigue negando la web de Zabbix desde el perimetro" no_llega e3 http 192.168.30.10/zabbix/
    comprobar "Sin E5, R1 sigue negando Multi-WAN -> ADMIN" no_llega e3 ping 192.168.10.50
    comprobar "Sin E5, R1 abre TCP 10051 de Zabbix a los enlaces de transito (agente de E4)" llega e4 tcp 192.168.30.10 10051
    comprobar "Sin E5, R1 no abre TCP 10051 de Zabbix a la DMZ (WEB01)" no_llega web01 tcp 192.168.30.10 10051
    comprobar "Sin E5, esos intentos los nego la regla final de R1 (PERIMETRO->LAN)" cuenta 'PERIMETRO->LAN'
    comprobar "Frontera E1/E5: sin E5, VPN-USERS llegaria a ADMIN (R1 no repite la politica VPN: es de E5, ADR-0002)" llega vpn-users ping 192.168.10.50
fi
comprobar "Poda: la VLAN 30 no existe en la troncal de SW-ACC01" bash -c "! ip netns exec sw-acc01 bridge vlan show dev p0 | grep -qw 30"
comprobar "Sin VLAN 1: ningun puerto de SW-CORE01 tiene la VLAN 1" bash -c "! ip netns exec sw-core01 bridge vlan show | awk 'NR>1 {print \$NF==\"\" ? \$1 : \$0}' | grep -qw 1"
comprobar "SPAN: el puerto espejo p5 de SW-CORE01 transmitio copias" bash -c "[ \"\$(ip netns exec sw-core01 cat /sys/class/net/p5/statistics/tx_packets)\" -gt 20 ]"
comprobar "ACL: la regla USERS->ADMIN conto paquetes bloqueados" bash -c "ip netns exec r1-lan nft list chain inet xelaju desde_users | grep 'USERS->ADMIN' | grep -q -v 'packets 0 '"
comprobar "ACL: el binding MAC.IP conto paquetes del intruso" bash -c "ip netns exec r1-lan nft list ruleset | grep 'USERS-NOREG' | grep -q -v 'packets 0 '"

# ---- 9. Estado de capa 2 y contadores (evidencia) ------------------------------
{
    echo; echo "##### Estado de los switches #####"
    for sw in sw-core01 sw-acc01; do
        echo; XJ_ETC="$REPO/nodos/$sw" en "$sw" "$REPO/nodos/_comun/switch/switch-mostrar" todo
    done
    echo; echo "##### R1-LAN: interfaces, rutas y reglas con paquetes contados #####"
    en r1-lan ip -br addr show | grep -v '^lo '
    en r1-lan ip route show
    en r1-lan nft list table inet xelaju | grep -E 'chain |counter packets [1-9]'
} >> "$SALIDA" 2>&1
if [ "$DETALLE" -eq 1 ]; then sed -n '/##### Estado de los switches/,$p' "$SALIDA"; fi

# ---- 10. Resumen -----------------------------------------------------------------
DESTINO="$REPO/evidencias/simulacion"
if mkdir -p "$DESTINO" 2>/dev/null; then
    COPIA="$DESTINO/simulacion-$MODO-$(date +%Y%m%d-%H%M%S).txt"
    cp "$SALIDA" "$COPIA"
fi
paso "RESULTADO del ensayo en modo $MODO"
echo "   Matriz: $TOTAL_PASS PASS, $TOTAL_FAIL FAIL, $TOTAL_OMIT omitidas (las omitidas son las de DHCP, que aqui no se simula)"
echo "   Comprobaciones adicionales con fallo: $EXTRA_FAIL"
[ -n "${COPIA:-}" ] && echo "   Detalle completo: ${COPIA#"$REPO"/}"
rm -rf "$TMP"
if [ "$TOTAL_FAIL" -eq 0 ] && [ "$EXTRA_FAIL" -eq 0 ] && [ "$TOTAL_PASS" -gt 0 ]; then exit 0; else exit 1; fi
