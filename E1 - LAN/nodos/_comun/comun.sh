#!/bin/bash
# =============================================================================
# nodos/_comun/comun.sh - funciones que comparten los aplicar.sh de los nodos
#
# No se ejecuta sola. Cada nodos/<nodo>/aplicar.sh la carga con:
#     . "$XJ_REPO/nodos/_comun/comun.sh"
#
# Todas las funciones son idempotentes: se pueden repetir sin romper nada, de
# modo que aplicar.sh sirve tambien para RESTAURAR un nodo a su estado conocido.
# =============================================================================

XJ_REPO="${XJ_REPO:-/mnt/proyecto}"
XJ_TOPO="$XJ_REPO/lab/topologia.conf"
XJ_ESTADO=/var/lib/xelaju
XJ_RESPALDOS=/var/backups/xelaju
XJ_ZBX=192.168.30.10
XJ_ZABBIX_RELEASE_URL="https://repo.zabbix.com/zabbix/7.0/debian/pool/main/z/zabbix-release/zabbix-release_latest_7.0+debian13_all.deb"
XJ_APT_ACTUALIZADO=0
export DEBIAN_FRONTEND=noninteractive
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# ---- Mensajes ---------------------------------------------------------------
xj_paso()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
xj_ok()    { printf '    [ OK ] %s\n' "$*"; }
xj_aviso() { printf '    \033[1;33m[AVISO]\033[0m %s\n' "$*" >&2; }
xj_morir() { printf '    \033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

xj_requerir_root() {
    if [ "$(id -u)" -ne 0 ]; then xj_morir "hay que ejecutarlo como root:  sudo $0"; fi
    [ -r "$XJ_TOPO" ] || xj_morir "no se ve el repositorio en $XJ_REPO (falta /mnt/proyecto?)"
    mkdir -p "$XJ_ESTADO"
}

# ---- Copia de archivos de configuracion --------------------------------------
# xj_instalar <origen> <destino> [modo] [dueno:grupo]
# Si el destino ya existe y es distinto, guarda antes una copia fechada.
xj_instalar() {
    local origen="$1" destino="$2" modo="${3:-0644}" dueno="${4:-root:root}" copia
    [ -e "$origen" ] || xj_morir "falta $origen en el repositorio"
    if [ -f "$destino" ] && ! cmp -s "$origen" "$destino"; then
        copia="$XJ_RESPALDOS/$(date +%Y%m%d-%H%M%S)$destino"
        mkdir -p "$(dirname "$copia")"
        cp -a "$destino" "$copia"
    fi
    install -D -m "$modo" -o "${dueno%%:*}" -g "${dueno##*:}" "$origen" "$destino"
}

# xj_instalar_arbol <directorio rootfs>
# Copia sobre / todo lo que hay bajo rootfs/ conservando las rutas.
# Lo que va a usr/local/sbin se instala ejecutable; el resto, como dato.
xj_instalar_arbol() {
    local raiz="$1" f modo n=0
    [ -d "$raiz" ] || xj_morir "no existe $raiz"
    while IFS= read -r f; do
        case "$f" in
            usr/local/sbin/*|usr/local/bin/*) modo=0755 ;;
            *) modo=0644 ;;
        esac
        xj_instalar "$raiz/$f" "/$f" "$modo"
        n=$((n + 1))
    done < <(cd "$raiz" && find . -type f | sed 's|^\./||' | sort)
    xj_ok "$n archivos instalados desde ${raiz#"$XJ_REPO"/}"
}

# xj_conf <archivo> <Clave> <valor>: deja una linea "Clave=valor" en un archivo
# de estilo Zabbix (reemplaza la existente, o la primera comentada, o la agrega).
xj_conf() {
    local archivo="$1" clave="$2" valor="$3"
    if grep -q "^$clave=" "$archivo"; then
        sed -i "s|^$clave=.*|$clave=$valor|" "$archivo"
    elif grep -q "^# *$clave=" "$archivo"; then
        sed -i "0,/^# *$clave=.*/s||$clave=$valor|" "$archivo"
    else
        printf '%s=%s\n' "$clave" "$valor" >> "$archivo"
    fi
}

# ---- Identidad del nodo -------------------------------------------------------
# Las VMs son clones de una misma imagen: comparten machine-id y llaves SSH
# hasta que se regeneran aqui (una sola vez por nodo).
xj_identidad() {
    local nodo="$1"
    if ! hostnamectl set-hostname "$nodo" 2>/dev/null; then
        echo "$nodo" > /etc/hostname
        hostname "$nodo"
    fi
    if [ ! -e "$XJ_ESTADO/identidad" ]; then
        rm -f /etc/machine-id /var/lib/dbus/machine-id
        systemd-machine-id-setup >/dev/null 2>&1
        rm -f /etc/ssh/ssh_host_*
        ssh-keygen -A >/dev/null
        systemctl restart ssh 2>/dev/null || true
        date > "$XJ_ESTADO/identidad"
        xj_ok "machine-id y llaves SSH propias de $nodo"
    fi
    timedatectl set-timezone America/Guatemala 2>/dev/null || true
    # /etc/hosts: el propio nombre + los equipos del laboratorio
    {
        echo "127.0.0.1   localhost"
        echo "127.0.1.1   $nodo.xelajunetwork.lan $nodo"
        echo
        cat "$XJ_REPO/nodos/_comun/hosts.xelaju"
    } > /etc/hosts
    xj_ok "nombre de equipo: $nodo"
}

# ---- Nombres de interfaz fijos por MAC ----------------------------------------
# xj_dispositivo_de_mac <mac>: nombre actual de la tarjeta REAL con esa MAC.
# Las VLAN y los bridges heredan la MAC de su tarjeta pero no tienen "device".
xj_dispositivo_de_mac() {
    local d
    for d in /sys/class/net/*; do
        [ -e "$d/device" ] || continue
        if [ "$(cat "$d/address")" = "$1" ]; then basename "$d"; return 0; fi
    done
    return 0
}

# xj_interfaces_por_mac <nodo>
# Por cada "nic" del nodo en topologia.conf:
#   1. escribe un archivo .link de systemd (MAC -> nombre) para los proximos arranques
#   2. renombra la tarjeta ahora mismo, sin reiniciar
xj_interfaces_por_mac() {
    local nodo="$1" ifn mac actual archivo contenido cambios=0
    mkdir -p /etc/systemd/network
    while read -r ifn mac; do
        archivo="/etc/systemd/network/10-xelaju-$ifn.link"
        contenido="$(printf '# Generado por comun.sh a partir de lab/topologia.conf\n[Match]\nMACAddress=%s\nType=ether\n\n[Link]\nName=%s' "$mac" "$ifn")"
        if [ "$(cat "$archivo" 2>/dev/null)" != "$contenido" ]; then
            printf '%s\n' "$contenido" > "$archivo"
            cambios=1
        fi
        actual="$(xj_dispositivo_de_mac "$mac")"
        if [ -z "$actual" ]; then
            xj_aviso "ninguna tarjeta tiene la MAC $mac (deberia ser $ifn)"
        elif [ "$actual" != "$ifn" ]; then
            ip link set dev "$actual" down
            ip link set dev "$actual" name "$ifn"
            xj_ok "interfaz $actual -> $ifn ($mac)"
        fi
    done < <(sed -e 's/#.*//' "$XJ_TOPO" | awk -v n="$nodo" '$1=="nic" && $2==n {print $3, $4}')
    if [ "$cambios" -eq 1 ]; then
        # El initramfs lleva una copia de los .link: se regenera para que los
        # nombres ya sean los definitivos desde el arranque.
        xj_ok "archivos .link escritos; actualizando initramfs (tarda unos segundos)"
        update-initramfs -u >/dev/null 2>&1 || xj_aviso "update-initramfs fallo (los nombres se aplican igual al arrancar)"
    fi
}

# ---- Red con ifupdown ----------------------------------------------------------
# xj_red_detener: baja todo lo que ifupdown tenga configurado (menos lo).
# Se llama ANTES de cambiar /etc/network/interfaces, mientras aun describe lo
# que esta levantado.
xj_red_detener() {
    local i
    for i in $(ifquery --state 2>/dev/null | cut -d= -f1); do
        if [ "$i" != lo ]; then ifdown --force "$i" >/dev/null 2>&1 || true; fi
    done
    pkill -x dhclient 2>/dev/null || true
}

# xj_red_iniciar: levanta las interfaces "auto" y las "allow-hotplug".
xj_red_iniciar() {
    local i
    ifup -a || xj_aviso "ifup -a devolvio error"
    for i in $(ifquery --list --allow=hotplug 2>/dev/null); do
        if ! ifquery --state "$i" >/dev/null 2>&1; then ifup "$i" || xj_aviso "no se pudo levantar $i"; fi
    done
}

# xj_resolv: DNS publicos fijos (sirven en modo individual y en modo grupal).
# No se usa en los clientes DHCP: ahi los entrega el servidor DHCP de R1.
xj_resolv() {
    rm -f /etc/resolv.conf
    printf '# XelajuNetwork: DNS publicos\nnameserver 8.8.8.8\nnameserver 1.1.1.1\n' > /etc/resolv.conf
}

# ---- Base comun de todos los nodos ---------------------------------------------
# xj_base <nodo>: identidad, nombres de interfaz y ajustes comunes del kernel.
xj_base() {
    local nodo="$1"
    xj_paso "Base comun del nodo $nodo"
    xj_identidad "$nodo"
    xj_red_detener
    xj_interfaces_por_mac "$nodo"
    xj_instalar "$XJ_REPO/nodos/_comun/sysctl-comun.conf" /etc/sysctl.d/80-xelaju-comun.conf
    sysctl -q -p /etc/sysctl.d/80-xelaju-comun.conf
}

# ---- Paquetes -------------------------------------------------------------------
xj_hay_internet() {
    curl -fsS -m 10 -o /dev/null http://deb.debian.org/debian/dists/trixie/Release 2>/dev/null
}

xj_apt() {
    apt-get -y -o DPkg::Lock::Timeout=120 -o Dpkg::Options::=--force-confold "$@"
}

# xj_paquetes <paquete>...: instala solo los que falten (necesita Internet).
xj_paquetes() {
    local p faltan=()
    for p in "$@"; do
        dpkg -s "$p" >/dev/null 2>&1 || faltan+=("$p")
    done
    if [ ${#faltan[@]} -eq 0 ]; then xj_ok "paquetes ya instalados: $*"; return 0; fi
    if ! xj_hay_internet; then
        xj_morir "sin salida a Internet para instalar: ${faltan[*]}
            Revisa que R1-LAN este configurado y en modo individual (r1-modo estado)."
    fi
    if [ "$XJ_APT_ACTUALIZADO" -eq 0 ]; then xj_apt update >/dev/null; XJ_APT_ACTUALIZADO=1; fi
    xj_apt install --no-install-recommends "${faltan[@]}"
    xj_ok "instalado: ${faltan[*]}"
}

# xj_sin_arranque <orden...>: ejecuta una instalacion SIN que dpkg arranque los
# servicios recien instalados. policy-rc.d es el mecanismo estandar de Debian:
# si devuelve 101, invoke-rc.d no inicia nada. Asi un servicio no se levanta
# con la configuracion de fabrica antes de recibir la nuestra.
xj_sin_arranque() {
    local rc=0
    printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d
    chmod 0755 /usr/sbin/policy-rc.d
    # En un subshell: aunque la orden termine con error, policy-rc.d se borra
    # siempre (si se quedara, ningun servicio arrancaria al instalarse despues).
    ( "$@" ) || rc=$?
    rm -f /usr/sbin/policy-rc.d
    return "$rc"
}

# ---- Agente de Zabbix -----------------------------------------------------------
xj_repo_zabbix() {
    if dpkg -s zabbix-release >/dev/null 2>&1; then return 0; fi
    curl -fsSL -m 60 -o /tmp/zabbix-release.deb "$XJ_ZABBIX_RELEASE_URL" || return 1
    dpkg -i /tmp/zabbix-release.deb >/dev/null || return 1
    rm -f /tmp/zabbix-release.deb
    xj_apt update >/dev/null
    XJ_APT_ACTUALIZADO=1
}

# xj_agente_zabbix <Hostname> <HostMetadata> [servidor]
# Agente en modo ACTIVO: es el nodo quien abre la conexion al servidor
# (TCP 10051) y se registra solo gracias a HostMetadata (autorregistro).
xj_agente_zabbix() {
    local nombre="$1" meta="$2" servidor="${3:-$XJ_ZBX}" conf=/etc/zabbix/zabbix_agent2.conf
    if [ ! -f "$conf" ]; then
        if xj_hay_internet && xj_repo_zabbix && xj_apt install --no-install-recommends zabbix-agent2 >/dev/null; then
            xj_ok "zabbix-agent2 instalado"
        else
            xj_aviso "zabbix-agent2 no esta instalado y no hay Internet: este nodo no se monitorea todavia"
            return 0
        fi
    fi
    xj_conf "$conf" Server "$servidor"
    xj_conf "$conf" ServerActive "$servidor"
    xj_conf "$conf" Hostname "$nombre"
    xj_conf "$conf" HostMetadata "$meta"
    systemctl enable zabbix-agent2 >/dev/null 2>&1
    systemctl restart zabbix-agent2
    xj_ok "zabbix-agent2 activo: Hostname=$nombre HostMetadata=$meta ServerActive=$servidor"
}

# ---- Switch (bridge Linux con filtrado de VLAN) -----------------------------------
# xj_switch <dir del nodo>: instala las herramientas switch-* comunes, la
# configuracion propia del switch (switch.conf y puertos.conf) y el servicio
# que la aplica en cada arranque.
xj_switch() {
    local dir="$1" f
    xj_paso "Switch: tabla de puertos y VLAN"
    xj_instalar "$dir/switch.conf"  /etc/xelaju/switch.conf
    xj_instalar "$dir/puertos.conf" /etc/xelaju/puertos.conf
    for f in switch-aplicar switch-mostrar switch-span; do
        xj_instalar "$XJ_REPO/nodos/_comun/switch/$f" "/usr/local/sbin/$f" 0755
    done
    xj_instalar "$XJ_REPO/nodos/_comun/switch/xelaju-switch.service" /etc/systemd/system/xelaju-switch.service
    # ifupdown solo gestiona lo: los puertos y la IP de gestion son de switch-aplicar
    xj_instalar "$XJ_REPO/nodos/_comun/switch/interfaces" /etc/network/interfaces
    xj_resolv
    # Primero a mano, para ver en pantalla cualquier error de puertos.conf...
    /usr/local/sbin/switch-aplicar
    # ...y despues como servicio, para que se repita en cada arranque
    systemctl daemon-reload
    systemctl enable xelaju-switch.service >/dev/null 2>&1
    systemctl restart xelaju-switch.service
    xj_ok "xelaju-switch.service activo (se aplica en cada arranque)"
    switch-mostrar vlan
    switch-mostrar trunk
}

# ---- Cliente generico (PCs) ------------------------------------------------------
# xj_cliente <nodo> <dir del nodo>: base + /etc/network/interfaces del nodo.
xj_cliente() {
    local nodo="$1" dir="$2"
    xj_requerir_root
    xj_base "$nodo"
    xj_paso "Red de $nodo"
    xj_instalar "$dir/interfaces" /etc/network/interfaces
    if grep -q 'inet static' "$dir/interfaces"; then xj_resolv; fi
    xj_red_iniciar
    ip -br addr show
}

xj_fin() {
    xj_paso "Listo: $1"
    echo "    Para repetir o restaurar este nodo, vuelve a ejecutar este mismo script."
}
