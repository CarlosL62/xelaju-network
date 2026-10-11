#!/bin/bash
# =============================================================================
# lab/base/post-base.sh - ajustes finales de la imagen base
#
# Se ejecuta UNA sola vez, dentro del sistema recien instalado, al final de la
# instalacion desatendida (preseed/late_command). Deja listo lo que es igual
# para todas las VMs; lo propio de cada nodo lo hace despues su aplicar.sh.
#
# Nunca termina con error: un fallo aqui detendria al instalador con una
# pregunta en pantalla. Lo que no se pueda hacer se anota como AVISO y los
# aplicar.sh lo reintentan (por ejemplo, instalar el agente de Zabbix).
# =============================================================================
set -u
export DEBIAN_FRONTEND=noninteractive
REGISTRO=/var/log/xelaju-post-base.log
ZABBIX_RELEASE_URL="https://repo.zabbix.com/zabbix/7.0/debian/pool/main/z/zabbix-release/zabbix-release_latest_7.0+debian13_all.deb"

exec >> "$REGISTRO" 2>&1
consola() { echo "$*" > /dev/console 2>/dev/null || true; }
aviso()   { echo "AVISO: $*"; consola "XELAJU_AVISO: $*"; }

echo "=== post-base.sh: $(date) ==="

# ---- 1. Cliente DHCP ---------------------------------------------------------
# Los PC de usuarios piden su IP con dhclient (isc-dhcp-client, ya instalado
# por el preseed). Se quita dhcpcd para que ifupdown use siempre el mismo.
if dpkg -s dhcpcd-base >/dev/null 2>&1; then
    apt-get purge -y dhcpcd-base || aviso "no se pudo quitar dhcpcd-base"
fi

# ---- 2. Repositorio oficial de Zabbix 7.0 LTS y agente 2 ---------------------
# El agente queda instalado pero apagado: cada nodo lo configura y lo enciende.
if wget -q -O /tmp/zabbix-release.deb "$ZABBIX_RELEASE_URL" \
        && dpkg -i /tmp/zabbix-release.deb \
        && apt-get update \
        && apt-get install -y --no-install-recommends zabbix-agent2; then
    systemctl disable zabbix-agent2 || true
else
    aviso "no se pudo instalar zabbix-agent2 (los aplicar.sh lo reintentaran)"
fi
rm -f /tmp/zabbix-release.deb

# ---- 3. Carpetas compartidas con el host (9p sobre virtio) -------------------
# /mnt/proyecto   = este repositorio, solo lectura
# /mnt/evidencias = carpeta evidencias/, con escritura
# x-systemd.automount las monta en el primer acceso; nofail evita que el
# arranque falle si la VM se lanza sin esas carpetas.
mkdir -p /mnt/proyecto /mnt/evidencias
if ! grep -q '^proyecto[[:space:]]' /etc/fstab; then
    cat >> /etc/fstab <<'EOF'

# Carpetas compartidas del laboratorio XelajuNetwork (9p sobre virtio)
proyecto    /mnt/proyecto    9p  trans=virtio,version=9p2000.L,ro,nofail,x-systemd.automount  0  0
evidencias  /mnt/evidencias  9p  trans=virtio,version=9p2000.L,rw,nofail,x-systemd.automount  0  0
EOF
fi
printf '9p\n9pnet_virtio\n' > /etc/modules-load.d/xelaju-9p.conf

# ---- 4. Consola serie ----------------------------------------------------------
# GRUB y el kernel hablan por la pantalla (tty0, para los PC con escritorio) y
# por el puerto serie (ttyS0, que es lo que abre "lab.sh consola").
if [ -f /etc/default/grub ]; then
    sed -i -e '/^GRUB_TERMINAL=/d' -e '/^GRUB_SERIAL_COMMAND=/d' \
           -e 's|^GRUB_TIMEOUT=.*|GRUB_TIMEOUT=1|' \
           -e 's|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=""|' \
           -e 's|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX="console=tty0 console=ttyS0,115200n8"|' \
           /etc/default/grub
    cat >> /etc/default/grub <<'EOF'
GRUB_TERMINAL="console serial"
GRUB_SERIAL_COMMAND="serial --unit=0 --speed=115200 --word=8 --parity=no --stop=1"
EOF
    update-grub || aviso "update-grub fallo"
else
    aviso "no existe /etc/default/grub"
fi

# ---- 5. sudo -------------------------------------------------------------------
# Sin cuenta root, el instalador ya agrega al primer usuario al grupo sudo;
# se asegura por si acaso.
adduser xelaju sudo >/dev/null 2>&1 || aviso "no se pudo agregar xelaju al grupo sudo"

# ---- 6. Sin tareas automaticas de apt ------------------------------------------
# En un laboratorio compiten por el bloqueo de dpkg y buscan Internet en VMs
# que no la tienen.
systemctl disable apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1 || true

# ---- 7. Limpieza ---------------------------------------------------------------
apt-get clean

echo "=== post-base.sh terminado ==="
consola "XELAJU_POST_BASE=OK"
exit 0
