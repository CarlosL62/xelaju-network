#!/bin/bash
# =============================================================================
# pruebas/validar-estatico.sh - validacion del repositorio SIN levantar VMs
#
# Se ejecuta en el host, sin root, en pocos segundos. Conviene pasarla despues
# de cualquier cambio y antes de copiar el repositorio a otra maquina.
#
#   1. Sintaxis de todos los scripts de shell          (bash -n)
#   2. Sintaxis de los programas de Python             (py_compile)
#   3. Reglas de nftables de R1 (modo individual y grupal) y de ZBX:
#      sintaxis (nft -c) y carga real en el kernel, dentro de un namespace de
#      red aislado para no tocar el cortafuegos del host   (unshare -rn)
#   4. Coherencia de IP, MAC, VLAN y puertos entre archivos (consistencia.py)
#   5. Registro DHCP: CSV valido y archivos generados al dia (xelaju-dhcp)
#   6. Archivos de datos: unidad systemd, XML del diagrama
#
# El ensayo funcional (VLAN + rutas + ACL con trafico real) es otro script:
#   ./pruebas/simular-lan.sh [individual|grupal]
# =============================================================================
set -u
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export LC_ALL=C

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO" || exit 1
FALLOS=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

titulo() { printf '\n%s\n' "$*"; }
bien()   { printf '  [ OK ] %s\n' "$*"; }
mal()    { printf '  [FALLO] %s\n' "$*"; FALLOS=$((FALLOS + 1)); }
nota()   { printf '  [ -- ] %s\n' "$*"; }

# ---- 1. Shell -------------------------------------------------------------------
titulo "1. Sintaxis de los scripts de shell (bash -n)"
n=0
while IFS= read -r f; do
    if bash -n "$f" 2> "$TMP/err"; then n=$((n + 1)); else mal "$f: $(head -1 "$TMP/err")"; fi
done < <(grep -rIl --exclude-dir=.git --exclude-dir=imagenes --exclude-dir=vms --exclude-dir=run \
             -E '^#!/bin/(ba)?sh' . | sort)
bien "$n scripts sin errores de sintaxis"
if command -v shellcheck >/dev/null; then
    nota "shellcheck disponible: ejecute 'shellcheck -x <script>' para un analisis mas fino"
fi

# ---- 2. Python ------------------------------------------------------------------
titulo "2. Sintaxis de los programas de Python"
for f in lab/qemuctl.py pruebas/consistencia.py nodos/zbx-srv01/monitoreo.py grupal/isp-panel.py; do
    if python3 -c "import py_compile, sys; py_compile.compile(sys.argv[1], cfile='$TMP/x.pyc', doraise=True)" "$f" 2> "$TMP/err"; then
        bien "$f"
    else
        mal "$f: $(tail -1 "$TMP/err")"
    fi
done

# ---- 3. nftables ----------------------------------------------------------------
titulo "3. Reglas de nftables (sintaxis y carga real en un namespace aislado)"
# preparar_r1 <modo>: copia las reglas de R1 a un directorio temporal, pone el
# archivo del modo como 20-modo.nft (en R1 es un enlace simbolico) y apunta el
# include a esa copia. Imprime la ruta del nftables.conf preparado.
preparar_r1() {
    local d="$TMP/r1-$1"
    mkdir -p "$d"
    cp -r nodos/r1-lan/rootfs/etc/nftables.conf nodos/r1-lan/rootfs/etc/nftables.d "$d/"
    cp "$d/nftables.d/modos/$1.nft" "$d/nftables.d/20-modo.nft"
    sed -i "s|/etc/nftables.d|$d/nftables.d|" "$d/nftables.conf"
    echo "$d/nftables.conf"
}
if ! command -v nft >/dev/null; then
    nota "nft no esta instalado en el host: se omite (sudo apt install nftables)"
elif ! unshare -rn true 2>/dev/null; then
    nota "este sistema no permite namespaces sin root: se omite"
else
    for modo in individual grupal; do
        conf="$(preparar_r1 "$modo")"
        if unshare -rn nft -c -f "$conf" 2> "$TMP/err"; then
            reglas="$(unshare -rn sh -c "nft -f '$conf' && nft list ruleset | grep -c counter" 2> "$TMP/err")"
            if [ -n "$reglas" ]; then bien "R1-LAN modo $modo: sintaxis correcta y $reglas reglas cargadas en el kernel"
            else mal "R1-LAN modo $modo: nft -c pasa pero el kernel rechaza la carga: $(head -1 "$TMP/err")"; fi
        else
            mal "R1-LAN modo $modo: $(head -3 "$TMP/err" | tr '\n' ' ')"
        fi
    done
    nat_i="$(unshare -rn sh -c "nft -f '$TMP/r1-individual/nftables.conf' && nft list ruleset | grep -c 'type nat'" 2>/dev/null)"
    nat_g="$(unshare -rn sh -c "nft -f '$TMP/r1-grupal/nftables.conf' && nft list ruleset | grep -c 'type nat'" 2>/dev/null)"
    if [ "${nat_i:-0}" -eq 1 ] && [ "${nat_g:-1}" -eq 0 ]; then bien "NAT solo en modo individual (grupal: sin cadena nat)"
    else mal "NAT: individual=${nat_i:-?} cadenas, grupal=${nat_g:-?} (se esperaba 1 y 0)"; fi
    conf=nodos/zbx-srv01/rootfs/etc/nftables.conf
    if unshare -rn sh -c "nft -c -f $conf && nft -f $conf" 2> "$TMP/err"; then bien "ZBX-SRV01: sintaxis correcta y reglas cargadas"
    else mal "ZBX-SRV01: $(head -3 "$TMP/err" | tr '\n' ' ')"; fi
fi

# ---- 4. Coherencia ---------------------------------------------------------------
titulo "4. Coherencia entre archivos (pruebas/consistencia.py)"
if python3 pruebas/consistencia.py > "$TMP/cons" 2>&1; then
    bien "$(grep -c '\[ OK \]' "$TMP/cons") comprobaciones, todas coinciden"
else
    grep -E 'FALLO|Traceback|Error' "$TMP/cons" | sed 's/^/  /'
    mal "consistencia.py encontro incoherencias (ejecutelo para ver el detalle)"
fi

# ---- 5. Registro DHCP -------------------------------------------------------------
titulo "5. Registro de equipos del DHCP restringido (xelaju-dhcp verificar)"
R=nodos/r1-lan/rootfs
if XJ_CSV="$R/etc/xelaju/usuarios.csv" XJ_RESERVAS="$R/etc/dhcp/reservas-vlan20.conf" \
   XJ_SET_NFT="$R/etc/nftables.d/10-registrados.nft" XJ_SIN_SERVICIOS=1 \
   "$R/usr/local/sbin/xelaju-dhcp" verificar > "$TMP/dhcp" 2>&1; then
    bien "CSV valido; reservas de dhcpd y conjunto de nftables generados al dia"
else
    sed 's/^/  /' "$TMP/dhcp"
    mal "el CSV y los archivos generados no coinciden"
fi

# ---- 6. Archivos de datos ----------------------------------------------------------
titulo "6. Otros archivos"
if command -v systemd-analyze >/dev/null; then
    if systemd-analyze verify nodos/_comun/switch/xelaju-switch.service 2> "$TMP/err"; then
        bien "xelaju-switch.service: unidad valida"
    elif grep -q -v -E 'switch-aplicar|No such file|not found|no existe' "$TMP/err"; then
        mal "xelaju-switch.service: $(grep -v -E 'switch-aplicar|No such file' "$TMP/err" | head -1)"
    else
        bien "xelaju-switch.service: unidad valida (solo falta el ejecutable, que existe en la VM)"
    fi
fi
if [ -f docs/diagramas/estudiante1-lan.drawio ]; then
    if command -v xmllint >/dev/null; then
        if xmllint --noout docs/diagramas/estudiante1-lan.drawio 2> "$TMP/err"; then bien "diagrama draw.io: XML bien formado"
        else mal "diagrama draw.io: $(head -1 "$TMP/err")"; fi
    else
        nota "xmllint no esta instalado: no se valida el XML del diagrama"
    fi
fi
if grep -q '@@HASH@@' lab/base/preseed.cfg.plantilla && ! grep -rq '\$6\$' lab/base/ 2>/dev/null; then
    bien "preseed: la plantilla lleva el marcador @@HASH@@ y no hay ningun hash de contrasena en el repositorio"
else
    mal "preseed: falta @@HASH@@ en la plantilla o hay un hash de contrasena guardado en lab/base/"
fi

titulo "RESULTADO"
if [ "$FALLOS" -eq 0 ]; then echo "  Validacion estatica correcta."; exit 0
else echo "  $FALLOS problema(s) encontrados."; exit 1; fi
