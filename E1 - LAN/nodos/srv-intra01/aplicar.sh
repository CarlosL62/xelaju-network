#!/bin/bash
# =============================================================================
# nodos/srv-intra01/aplicar.sh - configura (o restaura) SRV-INTRA01
#
# Servidor de Intranet: nginx en los puertos 80 y 443. Es el servicio que los
# usuarios SI pueden usar de la VLAN de servidores (prueba de la ACL).
# Necesita salida a Internet para instalar nginx (R1-LAN en modo individual).
# Uso, dentro de la VM:   sudo /mnt/proyecto/nodos/srv-intra01/aplicar.sh
# =============================================================================
set -euo pipefail

NODO=srv-intra01
AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
XJ_REPO="$(cd "$AQUI/../.." && pwd)"
. "$XJ_REPO/nodos/_comun/comun.sh"

xj_requerir_root
xj_base "$NODO"

xj_paso "Red: IP estatica 192.168.30.20 en la VLAN 30"
xj_instalar "$AQUI/rootfs/etc/network/interfaces" /etc/network/interfaces
xj_resolv
xj_red_iniciar

xj_paso "Paquetes: nginx y certificado autofirmado (ssl-cert)"
xj_paquetes nginx ssl-cert

xj_paso "Sitio de la Intranet (HTTP 80 y HTTPS 443)"
xj_instalar "$AQUI/rootfs/etc/nginx/sites-available/intranet" /etc/nginx/sites-available/intranet
xj_instalar "$AQUI/rootfs/var/www/intranet/index.html" /var/www/intranet/index.html
ln -sfn /etc/nginx/sites-available/intranet /etc/nginx/sites-enabled/intranet
rm -f /etc/nginx/sites-enabled/default
nginx -t 2>&1 | sed 's/^/    /'
systemctl enable nginx >/dev/null 2>&1
systemctl restart nginx
xj_ok "HTTP  -> $(curl -s -o /dev/null -m 5 -w '%{http_code}' http://127.0.0.1/ || true)"
xj_ok "HTTPS -> $(curl -sk -o /dev/null -m 5 -w '%{http_code}' https://127.0.0.1/ || true)"

xj_paso "Agente de Zabbix (modo activo, autorregistro 'xelaju-lan')"
xj_agente_zabbix SRV-INTRA01 xelaju-lan

xj_fin "SRV-INTRA01 (http://192.168.30.20 y https://192.168.30.20)"
