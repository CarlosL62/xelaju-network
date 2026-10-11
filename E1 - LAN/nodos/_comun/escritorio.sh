#!/bin/bash
# =============================================================================
# nodos/_comun/escritorio.sh - escritorio XFCE y Firefox ESR para un PC cliente
#
# El enunciado exige modo texto en la infraestructura, pero permite interfaz
# grafica en los clientes de prueba. Se usa en PC-ADMIN01 (para abrir la web de
# Zabbix) y en PC-USER01 (para navegar como usuario).
# Descarga unos 250 MB: el PC debe tener ya salida a Internet.
# No se llama directo: usar nodos/<pc>/escritorio.sh
# =============================================================================
set -euo pipefail

AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
XJ_REPO="$(cd "$AQUI/../.." && pwd)"
. "$XJ_REPO/nodos/_comun/comun.sh"

xj_requerir_root

xj_paso "Escritorio XFCE, gestor de sesion LightDM y Firefox ESR"
xj_paquetes xserver-xorg lightdm lightdm-gtk-greeter xfce4 xfce4-terminal \
            firefox-esr dbus-x11 fonts-dejavu-core tango-icon-theme

xj_paso "Arranque en modo grafico"
systemctl set-default graphical.target >/dev/null
systemctl restart lightdm
xj_fin "escritorio instalado: inicia sesion como 'xelaju' en la ventana de la VM"
