#!/bin/bash
# =============================================================================
# lab/lab.sh - Orquestador del laboratorio XelajuNetwork (Estudiante 1 - LAN)
#
# QEMU puro, sin libvirt y sin root: cada VM es un proceso qemu-system-x86_64
# y los "cables" de la LAN son tuneles UDP por 127.0.0.1 entre esos procesos
# (-netdev dgram). Todo sale de lab/topologia.conf.
#
#   ./lab/lab.sh ayuda          lista de ordenes
#
# Directorios que genera (ignorados por git):
#   lab/imagenes/  instalador netboot + imagen base debian13-base.qcow2
#   lab/vms/       un disco qcow2 por VM, respaldado en la imagen base
#   lab/run/       sockets (consola serie, QMP, agente), PID y registros
# =============================================================================
set -euo pipefail

LAB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$LAB")"
TOPO="$LAB/topologia.conf"
DIR_IMG="$LAB/imagenes"
DIR_VMS="$LAB/vms"
DIR_RUN="$LAB/run"
DIR_EVID="$REPO/evidencias"
IMG_BASE="$DIR_IMG/debian13-base.qcow2"
QEMU="${QEMU:-qemu-system-x86_64}"
QEMUCTL="$LAB/qemuctl.py"
ESPEJO="https://deb.debian.org/debian"
NETBOOT="$ESPEJO/dists/trixie/main/installer-amd64/current/images"
SECRETO="$LAB/base/.secreto-xelaju"      # contrasena de laboratorio generada (si no se escribio por teclado)
PAQUETES_HOST="qemu-system-x86 qemu-utils qemu-system-gui socat tmux python3 wget openssl cpio nftables tcpdump wireshark"

# ---- Mensajes ---------------------------------------------------------------
if [ -t 1 ]; then
    C_OK=$'\033[1;32m'; C_AV=$'\033[1;33m'; C_ER=$'\033[1;31m'; C_AZ=$'\033[1;34m'; C_0=$'\033[0m'
else
    C_OK=''; C_AV=''; C_ER=''; C_AZ=''; C_0=''
fi
info()  { printf '%s==>%s %s\n' "$C_AZ" "$C_0" "$*"; }
ok()    { printf '  %s[ OK ]%s %s\n' "$C_OK" "$C_0" "$*"; }
aviso() { printf '  %s[AVISO]%s %s\n' "$C_AV" "$C_0" "$*" >&2; }
fallo() { printf '  %s[ERROR]%s %s\n' "$C_ER" "$C_0" "$*" >&2; }
die()   { fallo "$*"; exit 1; }

# ---- Lectura de topologia.conf ----------------------------------------------
# Se quita el comentario de cada linea y se filtra por la primera palabra.
topo() { sed -e 's/#.*//' "$TOPO"; }

opcion() {      # opcion <clave> [valor por defecto]
    topo | awk -v k="$1" -v d="${2:-}" '$1=="opcion" && $2==k {v=$3; e=1} END{print e ? v : d}'
}
lista_vms()  { topo | awk '$1=="vm"{print $2}'; }
existe_vm()  { topo | awk -v v="$1" '$1=="vm" && $2==v {e=1} END{exit !e}'; }
campo_vm()   { topo | awk -v v="$1" -v n="$2" '$1=="vm" && $2==v {print $n}'; }  # 3=ram 4=cpus 5=pantalla 6=grupo
lista_nics() { topo | awk -v v="$1" '$1=="nic" && $2==v {print $3, $4, $5}'; }    # interfaz MAC conexion
indice_nic() { lista_nics "$1" | awk -v i="$2" '$1==i {print NR-1; e=1} END{exit !e}'; }

# objetivos <vm|grupo|todas>... -> una VM por linea, sin repetir
objetivos() {
    local a
    [ $# -gt 0 ] || { fallo "indica una VM, un grupo (infra|servidores|clientes) o 'todas'"; return 1; }
    for a in "$@"; do
        if [ "$a" = todas ]; then
            lista_vms
        elif existe_vm "$a"; then
            echo "$a"
        elif topo | awk -v g="$a" '$1=="vm" && $6==g {e=1} END{exit !e}'; then
            topo | awk -v g="$a" '$1=="vm" && $6==g {print $2}'
        else
            fallo "'$a' no es una VM ni un grupo de topologia.conf"; return 1
        fi
    done | awk '!visto[$0]++'
}

# puertos_cable <vm> <interfaz> <cNN> -> "puerto_local puerto_remoto"
# El primer nic que nombra el cable es el extremo A (puerto base+2N) y el
# segundo el extremo B (base+2N+1). Cada extremo envia al puerto del otro.
puertos_cable() {
    topo | awk -v vm="$1" -v ifn="$2" -v c="$3" -v base="$(opcion udp_base 40000)" '
        $1=="nic" && $5=="cable:" c { n++; if ($2==vm && $3==ifn) yo=n }
        END {
            if (n != 2 || !yo) exit 1
            a = base + 2 * (substr(c, 2) + 0); b = a + 1
            if (yo == 1) print a, b; else print b, a
        }'
}

# ---- Estado de una VM -------------------------------------------------------
pid_vm() { cat "$DIR_RUN/$1.pid" 2>/dev/null || true; }
viva() {
    local pid; pid="$(pid_vm "$1")"
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || return 1
    # El PID podria haberse reutilizado: se confirma que es el QEMU de esta VM
    [[ "$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)" == *"-name $1,"* ]]
}

# ---- Linea de comandos de QEMU ----------------------------------------------
# sin_cable <i>: backend de una tarjeta que no esta unida a nada (puerto SPAN,
# enlace grupal sin TAP). Es un hub interno de QEMU con DOS puertos: el de la
# tarjeta (n<i>) y un "sumidero" sin nadie al otro lado. Con un solo puerto el
# hub no acepta tramas y la cola de transmision de la tarjeta se queda llena
# dentro de la VM (tx timeouts); el sumidero las recibe y las descarta, y asi
# "lab.sh capturar" puede grabar lo que la VM envia por ese puerto.
sin_cable() {
    ARGS_RED+=(-netdev "hubport,id=n$1,hubid=$((100 + $1))" -netdev "hubport,id=sumidero$1,hubid=$((100 + $1))")
}

# args_red <vm>: llena ARGS_RED con un -netdev y un -device por cada nic.
# El netdev de la interfaz numero i (en orden de topologia.conf) se llama n<i>.
args_red() {
    local vm="$1" i=0 ifn mac con tipo dato loc rem
    ARGS_RED=()
    while read -r ifn mac con; do
        tipo="${con%%:*}"; dato="${con#*:}"
        case "$tipo" in
            cable)
                read -r loc rem < <(puertos_cable "$vm" "$ifn" "$dato") \
                    || die "el cable $dato debe aparecer exactamente en dos nic de topologia.conf"
                ARGS_RED+=(-netdev "dgram,id=n$i,local.type=inet,local.host=127.0.0.1,local.port=$loc,remote.type=inet,remote.host=127.0.0.1,remote.port=$rem")
                ;;
            nat)
                ARGS_RED+=(-netdev "user,id=n$i,net=10.0.2.0/24,host=10.0.2.2,dns=10.0.2.3,ipv6=off,hostfwd=tcp:127.0.0.1:$dato-10.0.2.15:22")
                ;;
            tap)
                if [ -d "/sys/class/net/$dato" ]; then          # modo grupal: el TAP ya lo creo uplinks-host.sh
                    ARGS_RED+=(-netdev "tap,id=n$i,ifname=$dato,script=no,downscript=no")
                else                                            # sin TAP: puerto sin cable
                    sin_cable "$i"
                fi
                ;;
            aislado)
                sin_cable "$i"
                ;;
            *)
                die "conexion desconocida '$con' en $vm/$ifn"
                ;;
        esac
        ARGS_RED+=(-device "virtio-net-pci,netdev=n$i,mac=$mac")
        i=$((i + 1))
    done < <(lista_nics "$vm")
}

# args_vm <vm>: llena ARGS con todo salvo la forma de lanzarla.
args_vm() {
    local vm="$1" ram cpus pantalla indice
    ram="$(campo_vm "$vm" 3)"; cpus="$(campo_vm "$vm" 4)"; pantalla="$(campo_vm "$vm" 5)"
    args_red "$vm"
    ARGS=(
        -name "$vm,process=xj-$vm"
        -machine q35,accel=kvm -cpu host -smp "$cpus" -m "$ram"
        -nodefaults -rtc base=utc
        -drive "file=$DIR_VMS/$vm.qcow2,if=virtio,format=qcow2,discard=unmap"
        # Consola serie en un socket (lab.sh consola) y copia en un registro
        -chardev "socket,id=serie,path=$DIR_RUN/$vm.serial,server=on,wait=off,logfile=$DIR_RUN/$vm.consola.log"
        -serial chardev:serie
        # QMP: control del hipervisor (apagar, capturar)
        -qmp "unix:$DIR_RUN/$vm.qmp,server=on,wait=off"
        # Canal del agente del invitado (lab.sh exec / probar)
        -chardev "socket,id=qga,path=$DIR_RUN/$vm.qga,server=on,wait=off"
        -device virtio-serial-pci
        -device "virtserialport,chardev=qga,name=org.qemu.guest_agent.0"
        # Carpetas compartidas 9p: el repositorio (solo lectura) y evidencias (escritura)
        -fsdev "local,id=fsproy,path=$REPO,security_model=none,readonly=on"
        -device "virtio-9p-pci,fsdev=fsproy,mount_tag=proyecto"
        -fsdev "local,id=fsevid,path=$DIR_EVID,security_model=none"
        -device "virtio-9p-pci,fsdev=fsevid,mount_tag=evidencias"
        -device virtio-rng-pci
        "${ARGS_RED[@]}"
        -pidfile "$DIR_RUN/$vm.pid"
    )
    case "$pantalla" in
        none)
            ARGS+=(-display none)
            ;;
        gtk)
            ARGS+=(-device virtio-vga -device qemu-xhci,id=xhci -device usb-tablet,bus=xhci.0)
            if [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] && [ -z "${LAB_SIN_GUI:-}" ]; then
                ARGS+=(-display gtk,zoom-to-fit=on)
            else                                # host sin escritorio: pantalla por VNC local
                indice="$(lista_vms | awk -v v="$vm" '$0==v {print NR}')"
                ARGS+=(-display none -vnc "127.0.0.1:$indice")
                aviso "$vm: sin entorno grafico en el host; pantalla en VNC 127.0.0.1:$((5900 + indice))"
            fi
            ;;
        *)
            die "pantalla desconocida '$pantalla' para $vm (use none o gtk)"
            ;;
    esac
}

con_pantalla() { [ "$(campo_vm "$1" 5)" != none ]; }

# ---- Ordenes ----------------------------------------------------------------
cmd_ayuda() {
    cat <<EOF
Uso: ./lab/lab.sh <orden> [argumentos]

Preparacion del host
  dependencias [--instalar]   muestra (o instala con sudo) los paquetes necesarios
  verificar                   revisa KVM, RAM, disco, QEMU, puertos UDP y topologia.conf
  base [--rehacer|--aceptar]  crea la imagen base Debian 13 (instalacion desatendida)
  clave                       cambia la contrasena de 'xelaju' en todas las VMs encendidas

Ciclo de vida   (<objetivo> = VM, grupo infra|servidores|clientes, o 'todas')
  crear    <objetivo>...      crea el disco de cada VM a partir de la imagen base
  iniciar  <objetivo>...      arranca las VMs
  detener  [--forzar] <objetivo>...   apagado ordenado; --forzar corta si no responde
  destruir [-s] <objetivo>... apaga y BORRA el disco de la VM (-s: sin preguntar)
  estado                      tabla de VMs, PID y consolas
  cables                      tabla de cables virtuales y sus puertos UDP

Trabajo con las VMs
  consola  <vm>               consola serie (salir con Ctrl+])
  tmux                        una ventana de tmux por cada VM encendida
  exec     <vm> <orden...>    ejecuta una orden como root dentro de la VM (agente QEMU)
  aplicar  <vm> [guion]       ejecuta nodos/<vm>/aplicar.sh dentro de la VM y muestra su salida
  capturar <vm> <interfaz> [segundos] [archivo.pcap]
                              captura un cable a .pcap (por omision 30 s, en evidencias/pcap/)
  probar   [perfil...]        corre pruebas/probar.sh en los clientes y junta los resultados
  qemu     <vm>               imprime la linea de comandos de QEMU de esa VM (no la arranca)
EOF
}

cmd_dependencias() {
    local p faltan=()
    for p in $PAQUETES_HOST; do
        dpkg -s "$p" >/dev/null 2>&1 || faltan+=("$p")
    done
    if [ ${#faltan[@]} -eq 0 ]; then
        ok "todos los paquetes del host estan instalados"
    else
        info "Faltan: ${faltan[*]}"
        if [ "${1:-}" = "--instalar" ]; then
            sudo apt-get update && sudo apt-get install -y "${faltan[@]}"
        else
            echo "    sudo apt install ${faltan[*]}"
        fi
    fi
    if ! { [ -r /dev/kvm ] && [ -w /dev/kvm ]; }; then
        echo "    sudo usermod -aG kvm \$USER    # y volver a iniciar sesion"
    fi
}

cmd_verificar() {
    local errores=0 v mayor menor ram_total=0 ram_disp libre_gb p vm n ocupados=""
    info "Verificando el host"

    # 1. KVM
    if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then ok "KVM accesible (/dev/kvm)"
    else fallo "sin acceso a /dev/kvm: sudo usermod -aG kvm \$USER y volver a iniciar sesion"; errores=$((errores + 1)); fi

    # 2. QEMU >= 7.2 (primer version con -netdev dgram)
    if command -v "$QEMU" >/dev/null; then
        v="$("$QEMU" --version | sed -n '1s/.*version \([0-9]*\.[0-9]*\).*/\1/p')"
        mayor="${v%%.*}"; menor="${v#*.}"
        if [ "$mayor" -gt 7 ] || { [ "$mayor" -eq 7 ] && [ "$menor" -ge 2 ]; }; then
            if [[ "$("$QEMU" -netdev help 2>&1)" == *dgram* ]]; then ok "QEMU $v con -netdev dgram"
            else fallo "QEMU $v no ofrece -netdev dgram"; errores=$((errores + 1)); fi
        else
            fallo "QEMU $v es anterior a 7.2 (hace falta -netdev dgram)"; errores=$((errores + 1))
        fi
    else
        fallo "no esta $QEMU: ./lab/lab.sh dependencias"; errores=$((errores + 1))
    fi

    # 3. Herramientas
    for p in qemu-img socat python3 wget openssl cpio gzip sha256sum ss; do
        command -v "$p" >/dev/null || { fallo "falta la herramienta '$p'"; errores=$((errores + 1)); }
    done
    for p in tmux tcpdump wireshark; do
        command -v "$p" >/dev/null || aviso "opcional: '$p' no esta instalado"
    done

    # 4. RAM
    for vm in $(lista_vms); do ram_total=$((ram_total + $(campo_vm "$vm" 3))); done
    ram_disp="$(awk '/MemAvailable/ {print int($2 / 1024)}' /proc/meminfo)"
    if [ "$ram_disp" -ge "$ram_total" ]; then ok "RAM: $ram_disp MB disponibles, el laboratorio completo usa $ram_total MB"
    else aviso "RAM: $ram_disp MB disponibles y el laboratorio completo usa $ram_total MB: arranca por grupos"; fi

    # 5. Disco
    libre_gb="$(df -BG --output=avail "$LAB" | tail -1 | tr -dc '0-9')"
    if [ "$libre_gb" -ge 12 ]; then ok "Disco: $libre_gb GB libres en $(df --output=target "$LAB" | tail -1)"
    else aviso "Disco: solo $libre_gb GB libres (base ~2 GB, Zabbix ~2 GB, cada PC con escritorio ~2 GB)"; fi

    # 6. Rutas: los sockets UNIX admiten 107 caracteres y QEMU separa opciones con comas
    if [ ${#DIR_RUN} -gt 85 ]; then fallo "la ruta $DIR_RUN es demasiado larga para los sockets"; errores=$((errores + 1)); fi
    case "$REPO" in *,*) fallo "la ruta del repositorio no puede contener comas"; errores=$((errores + 1)) ;; esac

    # 7. topologia.conf
    if topo | awk '
        $1=="vm"  { vm[$2]++ }
        $1=="nic" { nic[$2]=1; mac[$4]++; if ($5 ~ /^cable:/) cable[$5]++ }
        END {
            for (v in vm)   if (vm[v] > 1)     { print "VM repetida: " v; e=1 }
            for (v in nic)  if (!(v in vm))    { print "nic de una VM que no existe: " v; e=1 }
            for (m in mac)  if (mac[m] > 1)    { print "MAC repetida: " m; e=1 }
            for (c in cable) if (cable[c] != 2) { print c " debe tener 2 extremos y tiene " cable[c]; e=1 }
            exit e
        }'; then ok "topologia.conf coherente ($(lista_vms | wc -l) VMs, $(topo | grep -c 'cable:' | awk '{print $1/2}') cables)"
    else fallo "topologia.conf tiene errores (ver arriba)"; errores=$((errores + 1)); fi

    # 8. Puertos UDP de los cables y TCP del reenvio SSH
    n=0
    for vm in $(lista_vms); do viva "$vm" && n=$((n + 1)); done
    if [ "$n" -eq 0 ]; then
        ocupados="$(ss -Hlun 2>/dev/null | awk '{print $4}' | sed 's/.*://' | sort -u \
            | awk -v b="$(opcion udp_base 40000)" '$1 >= b && $1 < b + 64' | tr '\n' ' ')"
        if [ -z "$ocupados" ]; then ok "puertos UDP de los cables libres"
        else fallo "puertos UDP ocupados por otro programa: $ocupados"; errores=$((errores + 1)); fi
        p="$(topo | awk '$1=="nic" && $5 ~ /^nat:/ {sub("nat:", "", $5); print $5}' | head -1)"
        if [ -n "$p" ] && ss -Hltn 2>/dev/null | awk -v p=":$p" 'index($4, p) && substr($4, length($4) - length(p) + 1) == p {e=1} END{exit !e}'; then
            fallo "el puerto TCP $p (SSH a R1) esta ocupado"; errores=$((errores + 1))
        fi
    else
        ok "hay $n VM(s) encendidas: se omite la prueba de puertos libres"
    fi

    # 9. Pantalla e imagen base
    [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || aviso "sin DISPLAY: las VMs con pantalla gtk usaran VNC"
    if [ -f "$IMG_BASE" ]; then ok "imagen base presente ($(du -h "$IMG_BASE" | cut -f1))"
    else aviso "falta la imagen base: ./lab/lab.sh base"; fi

    if [ "$errores" -eq 0 ]; then info "Host listo"; else die "$errores problema(s) por resolver"; fi
}

# pedir_clave: pide dos veces una contrasena por teclado y la imprime
pedir_clave() {
    local a b
    while :; do
        read -r -s -p "    Contrasena: " a < /dev/tty || die "no se pudo leer la contrasena"; echo > /dev/tty
        read -r -s -p "    Repitela:   " b < /dev/tty || die "no se pudo leer la contrasena"; echo > /dev/tty
        if [ -n "$a" ] && [ "$a" = "$b" ]; then break; fi
        aviso "vacia o no coinciden; intenta de nuevo"
    done
    printf '%s' "$a"
}

# clave: cambia la contrasena del usuario xelaju en TODAS las VMs encendidas.
# La contrasena se escribe por teclado; a cada VM viaja solo su hash, por el
# agente del invitado (no por la red).
cmd_clave() {
    local clave hash vm hechas=0
    [ -t 0 ] || die "esta orden pide la contrasena por teclado: ejecutela en una terminal"
    info "Nueva contrasena del usuario 'xelaju' para las VMs encendidas"
    clave="$(pedir_clave)"
    hash="$(printf '%s' "$clave" | openssl passwd -6 -stdin)"
    unset clave
    for vm in $(lista_vms); do
        if ! viva "$vm"; then aviso "$vm esta apagada: conserva la contrasena anterior"; continue; fi
        if python3 "$QEMUCTL" exec "$DIR_RUN/$vm.qga" -- "usermod -p '$hash' xelaju" < /dev/null; then
            ok "$vm"; hechas=$((hechas + 1))
        else
            fallo "$vm: no se pudo cambiar"
        fi
    done
    if [ "$hechas" -gt 0 ]; then rm -f "$SECRETO"; fi
    echo "    Cambiada en $hechas VM(s). La imagen base conserva la contrasena con que se creo."
}

sha_ok() {      # sha_ok <linux|initrd.gz>: compara con SHA256SUMS
    local nb="$DIR_IMG/netboot" esperado
    esperado="$(awk -v f="./netboot/debian-installer/amd64/$1" '$2==f {print $1}' "$nb/SHA256SUMS" 2>/dev/null)"
    [ -n "$esperado" ] && [ -f "$nb/$1" ] && [ "$(sha256sum "$nb/$1" | cut -d' ' -f1)" = "$esperado" ]
}

cmd_base() {
    local nb="$DIR_IMG/netboot" parcial="$IMG_BASE.parcial" f clave hash tmp disco ram consola
    case "${1:-}" in
        --aceptar)      # dar por buena una instalacion que termino sin la marca final
            [ -f "$parcial" ] || die "no hay instalacion parcial que aceptar"
            mv "$parcial" "$IMG_BASE"; chmod 444 "$IMG_BASE"; ok "imagen base aceptada"; return 0 ;;
        --rehacer)
            if ls "$DIR_VMS"/*.qcow2 >/dev/null 2>&1; then
                die "hay discos que dependen de la base actual: ./lab/lab.sh destruir todas"
            fi
            rm -f "$IMG_BASE" ;;
    esac
    if [ -f "$IMG_BASE" ]; then ok "la imagen base ya existe (use --rehacer para repetirla)"; return 0; fi
    for f in wget cpio gzip openssl sha256sum qemu-img "$QEMU"; do
        command -v "$f" >/dev/null || die "falta '$f': ./lab/lab.sh dependencias"
    done
    [ -r /dev/kvm ] && [ -w /dev/kvm ] || die "sin acceso a /dev/kvm"
    mkdir -p "$nb" "$DIR_RUN"
    disco="$(opcion disco_gb 12)"; ram="$(opcion base_ram_mb 2048)"

    info "1/4 Instalador netboot de Debian 13 (unos 53 MB) y verificacion SHA256"
    wget -q -O "$nb/SHA256SUMS" "$NETBOOT/SHA256SUMS" || die "no se pudo descargar SHA256SUMS (sin Internet?)"
    for f in linux initrd.gz; do
        if ! sha_ok "$f"; then
            wget -q --show-progress -O "$nb/$f" "$NETBOOT/netboot/debian-installer/amd64/$f"
            sha_ok "$f" || die "el SHA256 de $f no coincide con SHA256SUMS: descarga corrupta"
        fi
        ok "$f verificado"
    done

    info "2/4 Contrasena del usuario 'xelaju' de todas las VMs (en el preseed va solo su hash SHA-512)"
    if [ -t 0 ]; then
        clave="$(pedir_clave)"
        rm -f "$SECRETO"            # escrita por teclado: no queda en ningun archivo
    else
        # Sin terminal (ejecucion desatendida): contrasena de laboratorio generada
        # al azar y guardada solo para el dueno. Se cambia con: ./lab/lab.sh clave
        if [ ! -s "$SECRETO" ]; then ( umask 077; openssl rand -hex 8 > "$SECRETO" ); fi
        clave="$(cat "$SECRETO")"
        aviso "sin terminal: contrasena generada en lab/base/.secreto-xelaju (cambiela con ./lab/lab.sh clave)"
    fi
    hash="$(printf '%s' "$clave" | openssl passwd -6 -stdin)"
    unset clave

    info "3/4 Preseed y post-base.sh dentro del initrd"
    tmp="$(mktemp -d "$DIR_RUN/base.XXXXXX")"
    # El hash usa el alfabeto [./0-9A-Za-z$]: no choca con el separador '|' de sed
    sed -e "s|@@HASH@@|$hash|" "$LAB/base/preseed.cfg.plantilla" > "$tmp/preseed.cfg"
    cp "$LAB/base/post-base.sh" "$tmp/post-base.sh"
    cp "$nb/initrd.gz" "$tmp/initrd-xelaju.gz"
    # Un initrd puede ser la concatenacion de varios archivos cpio: el instalador
    # encuentra /preseed.cfg en su raiz y lo carga solo.
    ( cd "$tmp" && printf '%s\n' preseed.cfg post-base.sh | cpio --quiet -o -H newc | gzip -9 >> initrd-xelaju.gz )
    ok "initrd preparado"

    info "4/4 Instalacion desatendida (10-20 min). La VM se apaga sola al terminar."
    rm -f "$parcial" "$DIR_RUN/base.consola.log" "$DIR_RUN/base.serial" "$DIR_RUN/base.qmp"
    qemu-img create -q -f qcow2 "$parcial" "${disco}G"
    if [ -t 0 ]; then
        echo "    Se muestra la consola del instalador. Para abortar: Ctrl+A y luego X."
        consola=(-chardev "stdio,id=con,mux=on,signal=off,logfile=$DIR_RUN/base.consola.log"
                 -serial chardev:con -mon chardev=con,mode=readline)
    else
        echo "    Sin terminal: la consola del instalador queda en $DIR_RUN/base.consola.log"
        echo "    (socket $DIR_RUN/base.serial para intervenir; QMP en base.qmp para abortar)"
        consola=(-chardev "socket,id=con,path=$DIR_RUN/base.serial,server=on,wait=off,logfile=$DIR_RUN/base.consola.log"
                 -serial chardev:con -qmp "unix:$DIR_RUN/base.qmp,server=on,wait=off")
    fi
    "$QEMU" -name xelaju-base -machine q35,accel=kvm -cpu host -smp 2 -m "$ram" \
        -nodefaults -no-reboot -display none \
        "${consola[@]}" \
        -drive "file=$parcial,if=virtio,format=qcow2" \
        -netdev user,id=n0,ipv6=off -device virtio-net-pci,netdev=n0,mac=52:54:00:ba:5e:01 \
        -device virtio-rng-pci \
        -kernel "$nb/linux" -initrd "$tmp/initrd-xelaju.gz" \
        -append "auto=true priority=critical console=ttyS0,115200n8 DEBIAN_FRONTEND=text ---" || true
    rm -rf "$tmp"
    echo
    if grep -q "XELAJU_POST_BASE=OK" "$DIR_RUN/base.consola.log" 2>/dev/null; then
        mv "$parcial" "$IMG_BASE"; chmod 444 "$IMG_BASE"
        ok "imagen base lista: $IMG_BASE ($(du -h "$IMG_BASE" | cut -f1))"
        echo "    Siguiente paso: ./lab/lab.sh crear todas"
    else
        fallo "la instalacion no llego a la marca final (XELAJU_POST_BASE=OK)."
        echo "    Revisa $DIR_RUN/base.consola.log. Si el instalador termino bien de todas"
        echo "    formas, acepta la imagen con: ./lab/lab.sh base --aceptar"
        exit 1
    fi
}

cmd_crear() {
    local lista vm
    [ -f "$IMG_BASE" ] || die "falta la imagen base: ./lab/lab.sh base"
    lista="$(objetivos "$@")" || exit 1
    mkdir -p "$DIR_VMS"
    for vm in $lista; do
        if [ -f "$DIR_VMS/$vm.qcow2" ]; then ok "$vm: el disco ya existe"; continue; fi
        # Disco "copia en escritura": solo guarda lo que cambia respecto a la base.
        # La ruta de la base es relativa para que el repositorio se pueda mover.
        qemu-img create -q -f qcow2 -F qcow2 -b "../imagenes/$(basename "$IMG_BASE")" "$DIR_VMS/$vm.qcow2"
        ok "$vm: disco creado"
    done
}

iniciar_vm() {
    local vm="$1" i
    [ -f "$DIR_VMS/$vm.qcow2" ] || die "$vm no tiene disco: ./lab/lab.sh crear $vm"
    if viva "$vm"; then ok "$vm ya estaba encendida (PID $(pid_vm "$vm"))"; return 0; fi
    rm -f "$DIR_RUN/$vm".serial "$DIR_RUN/$vm".qmp "$DIR_RUN/$vm".qga "$DIR_RUN/$vm".pid
    args_vm "$vm"
    if con_pantalla "$vm"; then
        # Con ventana grafica se deja en segundo plano en lugar de -daemonize
        setsid "$QEMU" "${ARGS[@]}" > "$DIR_RUN/$vm.qemu.log" 2>&1 < /dev/null &
        for i in 1 2 3 4 5 6 7 8 9 10; do viva "$vm" && break; sleep 0.5; done
    else
        "$QEMU" "${ARGS[@]}" -daemonize > "$DIR_RUN/$vm.qemu.log" 2>&1 || true
    fi
    if viva "$vm"; then ok "$vm encendida (PID $(pid_vm "$vm"))"
    else fallo "$vm no arranco:"; sed 's/^/      /' "$DIR_RUN/$vm.qemu.log" >&2; return 1; fi
}

cmd_iniciar() {
    local lista vm
    lista="$(objetivos "$@")" || exit 1
    mkdir -p "$DIR_RUN" "$DIR_EVID"
    for vm in $lista; do iniciar_vm "$vm"; done
    echo "    Consola: ./lab/lab.sh consola <vm>   |   Estado: ./lab/lab.sh estado"
}

detener_vm() {
    local vm="$1" forzar="$2" i pid espera=45
    if ! viva "$vm"; then ok "$vm ya estaba apagada"; return 0; fi
    pid="$(pid_vm "$vm")"
    if [ "$forzar" -eq 1 ]; then espera=10; fi
    # Apagado ordenado: QEMU pulsa el "boton de encendido" (ACPI) y Debian se apaga solo
    python3 "$QEMUCTL" apagar "$DIR_RUN/$vm.qmp" >/dev/null 2>&1 || true
    for i in $(seq 1 "$espera"); do viva "$vm" || break; sleep 1; done
    if viva "$vm"; then
        if [ "$forzar" -eq 1 ]; then
            python3 "$QEMUCTL" salir "$DIR_RUN/$vm.qmp" >/dev/null 2>&1 || true
            sleep 1
            kill "$pid" 2>/dev/null || true
            aviso "$vm no respondio al apagado ordenado: se corto"
        else
            aviso "$vm sigue encendida tras 45 s: ./lab/lab.sh detener --forzar $vm"; return 0
        fi
    else
        ok "$vm apagada"
    fi
    rm -f "$DIR_RUN/$vm".serial "$DIR_RUN/$vm".qmp "$DIR_RUN/$vm".qga "$DIR_RUN/$vm".pid
}

cmd_detener() {
    local forzar=0 lista vm
    if [ "${1:-}" = "--forzar" ]; then forzar=1; shift; fi
    lista="$(objetivos "$@")" || exit 1
    # Orden inverso: primero clientes y servidores, al final los switches y R1
    for vm in $(printf '%s\n' $lista | tac); do detener_vm "$vm" "$forzar"; done
}

cmd_destruir() {
    local sin_preguntar=0 lista vm resp
    if [ "${1:-}" = "-s" ]; then sin_preguntar=1; shift; fi
    lista="$(objetivos "$@")" || exit 1
    if [ "$sin_preguntar" -eq 0 ]; then
        echo "Se BORRARAN los discos de:" $lista
        read -r -p "Escribe 'si' para continuar: " resp
        [ "$resp" = si ] || { echo "cancelado"; return 0; }
    fi
    for vm in $lista; do
        detener_vm "$vm" 1
        if [ -f "$DIR_VMS/$vm.qcow2" ]; then
            rm -f "$DIR_VMS/$vm.qcow2"
            ok "$vm: disco borrado"
        fi
        rm -f "$DIR_RUN/$vm".consola.log "$DIR_RUN/$vm".qemu.log
    done
}

cmd_estado() {
    local vm estado
    printf '%-13s %-11s %-9s %-8s %-7s %s\n' VM GRUPO ESTADO PID RAM_MB DISCO
    for vm in $(lista_vms); do
        if viva "$vm"; then estado="${C_OK}encendida${C_0}"; else estado="apagada  "; fi
        printf '%-13s %-11s %s %-8s %-7s %s\n' "$vm" "$(campo_vm "$vm" 6)" "$estado" \
            "$(viva "$vm" && pid_vm "$vm" || echo -)" "$(campo_vm "$vm" 3)" \
            "$( [ -f "$DIR_VMS/$vm.qcow2" ] && du -h "$DIR_VMS/$vm.qcow2" | cut -f1 || echo 'sin crear')"
    done
    if [ -d /sys/class/net/tap-r1-squid ]; then
        echo "Enlace grupal presente en el host (tap-r1-squid)."
    fi
}

cmd_cables() {
    printf '%-6s %-22s %-7s    %-22s %-7s\n' CABLE "EXTREMO A" UDP "EXTREMO B" UDP
    topo | awk -v base="$(opcion udp_base 40000)" '
        $1=="nic" && $5 ~ /^cable:/ {
            c = substr($5, 7)
            if (!(c in a)) { a[c] = $2 "/" $3; orden[++n] = c } else b[c] = $2 "/" $3
        }
        END {
            for (i = 1; i <= n; i++) {
                c = orden[i]; p = base + 2 * (substr(c, 2) + 0)
                printf "%-6s %-22s %-7d <-> %-22s %-7d\n", c, a[c], p, b[c], p + 1
            }
        }'
}

cmd_consola() {
    local vm="${1:-}"
    [ -n "$vm" ] && existe_vm "$vm" || die "uso: lab.sh consola <vm>"
    viva "$vm" || die "$vm esta apagada"
    command -v socat >/dev/null || die "falta socat"
    echo "--- consola de $vm: pulsa Enter para ver el login; Ctrl+] para salir ---"
    socat "-,raw,echo=0,escape=0x1d" "UNIX-CONNECT:$DIR_RUN/$vm.serial"
    echo
    echo "--- consola de $vm cerrada ---"
}

cmd_tmux() {
    local sesion=xelaju vm primero=1 orden
    command -v tmux >/dev/null || die "tmux no esta instalado: sudo apt install tmux"
    if tmux has-session -t "$sesion" 2>/dev/null; then exec tmux attach -t "$sesion"; fi
    for vm in $(lista_vms); do
        viva "$vm" || continue
        orden="$(printf '%q consola %q' "$LAB/lab.sh" "$vm")"
        if [ "$primero" -eq 1 ]; then tmux new-session -d -s "$sesion" -n "$vm" "$orden"; primero=0
        else tmux new-window -t "$sesion" -n "$vm" "$orden"; fi
    done
    [ "$primero" -eq 0 ] || die "no hay ninguna VM encendida"
    exec tmux attach -t "$sesion"
}

cmd_exec() {
    local vm="${1:-}"
    [ -n "$vm" ] && existe_vm "$vm" || die "uso: lab.sh exec <vm> <orden...>"
    shift
    [ $# -gt 0 ] || die "falta la orden a ejecutar"
    viva "$vm" || die "$vm esta apagada"
    python3 "$QEMUCTL" exec "$DIR_RUN/$vm.qga" -- "$@"
}

# esperar_agente <vm> [segundos]: espera a que la VM termine de arrancar
# (el agente del invitado responde cuando el sistema ya esta en marcha)
esperar_agente() {
    local vm="$1" limite="${2:-120}" i
    for i in $(seq 1 "$limite"); do
        if python3 "$QEMUCTL" agente "$DIR_RUN/$vm.qga" > /dev/null 2>&1 < /dev/null; then return 0; fi
        viva "$vm" || return 1
        sleep 1
    done
    return 1
}

# aplicar <vm> [guion]: ejecuta nodos/<vm>/aplicar.sh (u otro guion del nodo)
# DENTRO de la VM, como root, sin abrir la consola. El guion corre desligado
# del agente (sin limite de tiempo) y escribe en la carpeta compartida de
# evidencias; aqui se sigue ese registro hasta que termina.
cmd_aplicar() {
    local vm="${1:-}" guion="${2:-aplicar.sh}" nombre reg reg_vm rc cola
    [ -n "$vm" ] && existe_vm "$vm" || die "uso: lab.sh aplicar <vm> [guion]   (por omision aplicar.sh)"
    [ -f "$REPO/nodos/$vm/$guion" ] || die "no existe nodos/$vm/$guion"
    viva "$vm" || die "$vm esta apagada: ./lab/lab.sh iniciar $vm"
    info "$vm: esperando a que termine de arrancar"
    esperar_agente "$vm" 180 || die "$vm no responde (agente del invitado): revisa lab/run/$vm.consola.log"
    nombre="$vm-${guion%.sh}"
    mkdir -p "$DIR_EVID/consola"
    reg="$DIR_EVID/consola/$nombre.log"; reg_vm="/mnt/evidencias/consola/$nombre.log"
    rm -f "$reg" "$reg.rc"; : > "$reg"
    python3 "$QEMUCTL" exec "$DIR_RUN/$vm.qga" -- \
        "setsid nohup bash -c '/mnt/proyecto/nodos/$vm/$guion > $reg_vm 2>&1; echo \$? > $reg_vm.rc' > /dev/null 2>&1 < /dev/null &" < /dev/null \
        || die "no se pudo lanzar el guion en $vm"
    info "$vm: ejecutando nodos/$vm/$guion (registro: evidencias/consola/$nombre.log)"
    tail -n +1 -f "$reg" &
    cola=$!
    while [ ! -s "$reg.rc" ]; do
        if ! viva "$vm"; then kill "$cola" 2>/dev/null; die "$vm se apago durante la ejecucion"; fi
        sleep 1
    done
    sleep 1; kill "$cola" 2>/dev/null || true; wait "$cola" 2>/dev/null || true
    rc="$(cat "$reg.rc")"; rm -f "$reg.rc"
    if [ "$rc" = 0 ]; then ok "$vm: $guion termino bien"; else fallo "$vm: $guion termino con codigo $rc"; return 1; fi
}

cmd_capturar() {
    local vm="${1:-}" ifn="${2:-}" seg="${3:-30}" archivo="${4:-}" idx
    [ -n "$vm" ] && [ -n "$ifn" ] || die "uso: lab.sh capturar <vm> <interfaz> [segundos] [archivo.pcap]"
    existe_vm "$vm" || die "no existe la VM $vm"
    viva "$vm" || die "$vm esta apagada"
    idx="$(indice_nic "$vm" "$ifn")" || die "$vm no tiene la interfaz $ifn"
    [ -n "$archivo" ] || archivo="$DIR_EVID/pcap/$vm-$ifn-$(date +%Y%m%d-%H%M%S).pcap"
    case "$archivo" in /*) ;; *) archivo="$PWD/$archivo" ;; esac
    info "Captura en $vm/$ifn (netdev n$idx)"
    python3 "$QEMUCTL" capturar "$DIR_RUN/$vm.qmp" "n$idx" "$archivo" --segundos "$seg"
}

cmd_probar() {
    local matriz="$REPO/pruebas/matriz.conf" resumen perfil vm rc fallidos=0 hechos=0
    mkdir -p "$DIR_EVID/pruebas"
    resumen="$DIR_EVID/pruebas/resumen-$(date +%Y%m%d-%H%M%S).txt"
    while read -r perfil vm; do
        if [ $# -gt 0 ]; then case " $* " in *" $perfil "*) ;; *) continue ;; esac; fi
        if ! viva "$vm"; then aviso "$vm apagada: se omite el perfil '$perfil'"; continue; fi
        info "Perfil '$perfil' en $vm"
        set +e
        python3 "$QEMUCTL" exec --limite 900 "$DIR_RUN/$vm.qga" -- \
            "/bin/bash /mnt/proyecto/pruebas/probar.sh $perfil" < /dev/null 2>&1 | tee -a "$resumen"
        rc="${PIPESTATUS[0]}"
        set -e
        hechos=$((hechos + 1))
        [ "$rc" -eq 0 ] || fallidos=$((fallidos + 1))
    done < <(sed -e 's/#.*//' "$matriz" | awk '$1=="perfil" {print $2, $3}')
    echo
    [ "$hechos" -gt 0 ] || die "no se ejecuto ningun perfil"
    if [ "$fallidos" -eq 0 ]; then ok "$hechos perfil(es) sin fallos. Resumen: $resumen"
    else fallo "$fallidos de $hechos perfil(es) con fallos. Resumen: $resumen"; exit 1; fi
}

cmd_qemu() {
    local vm="${1:-}"
    [ -n "$vm" ] && existe_vm "$vm" || die "uso: lab.sh qemu <vm>"
    args_vm "$vm"
    local a
    printf '%s' "$QEMU"
    for a in "${ARGS[@]}"; do
        case "$a" in
            -*) printf ' \\\n    %s' "$a" ;;      # cada opcion en su linea
            *)  printf ' %q' "$a" ;;
        esac
    done
    printf '\n'
}

# ---- Entrada ----------------------------------------------------------------
[ -r "$TOPO" ] || die "no se encuentra $TOPO"
orden="${1:-ayuda}"
[ $# -gt 0 ] && shift
case "$orden" in
    ayuda|-h|--help) cmd_ayuda ;;
    dependencias)    cmd_dependencias "$@" ;;
    verificar)       cmd_verificar ;;
    base)            cmd_base "$@" ;;
    clave)           cmd_clave ;;
    crear)           cmd_crear "$@" ;;
    iniciar)         cmd_iniciar "$@" ;;
    detener)         cmd_detener "$@" ;;
    destruir)        cmd_destruir "$@" ;;
    estado)          cmd_estado ;;
    cables)          cmd_cables ;;
    consola)         cmd_consola "$@" ;;
    tmux)            cmd_tmux ;;
    exec)            cmd_exec "$@" ;;
    aplicar)         cmd_aplicar "$@" ;;
    capturar)        cmd_capturar "$@" ;;
    probar)          cmd_probar "$@" ;;
    qemu)            cmd_qemu "$@" ;;
    *)               fallo "orden desconocida: $orden"; cmd_ayuda; exit 1 ;;
esac
