#!/bin/bash
# =============================================================================
# nodos/r1-lan/aplicar.sh - configura (o restaura) R1-LAN
#
# R1-LAN es el router inter-VLAN de la LAN: troncal 802.1Q, una subinterfaz
# por VLAN, ACL entre redes con nftables y DHCP restringido en la VLAN 20.
#
# Uso, dentro de la VM, por consola:
#     sudo /mnt/proyecto/nodos/r1-lan/aplicar.sh
# Se puede repetir las veces que haga falta: deja el nodo en el estado del
# repositorio y guarda copia de lo que cambie en /var/backups/xelaju/.
# Conserva el modo (individual/grupal) que hubiera; la primera vez, individual.
# =============================================================================
set -euo pipefail

NODO=r1-lan
AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
XJ_REPO="$(cd "$AQUI/../.." && pwd)"
. "$XJ_REPO/nodos/_comun/comun.sh"

xj_requerir_root

# Modo en que estaba el router antes de tocar nada
MODO=individual
case "$(readlink /etc/network/interfaces.d/uplinks 2>/dev/null || true)" in
    */grupal) MODO=grupal ;;
esac

xj_base "$NODO"

xj_paso "Archivos de configuracion y herramientas (rootfs/ -> /)"
xj_instalar_arbol "$AQUI/rootfs"
mkdir -p /etc/network/interfaces.d
systemctl daemon-reload

xj_paso "Router: reenvio IPv4, troncal y una subinterfaz por VLAN"
sysctl -q -p /etc/sysctl.d/90-xelaju-router.conf
xj_resolv
xj_red_iniciar
xj_ok "ip_forward=$(sysctl -n net.ipv4.ip_forward)"

xj_paso "Modo de salida: $MODO (enlaces de salida + reglas nftables)"
r1-modo "$MODO"
# r1-modo ya cargo las reglas con "nft -f". Se habilita el servicio para que
# las cargue en cada arranque y se inicia ahora para que figure como activo
# (vuelve a cargar el mismo archivo en una sola transaccion: no deja huecos).
systemctl enable nftables >/dev/null 2>&1
systemctl start nftables

xj_paso "Paquetes: servidor DHCP (isc-dhcp-server) y conntrack"
# Sin arrancar el servicio al instalarlo: todavia tendria la configuracion de fabrica
xj_sin_arranque xj_paquetes isc-dhcp-server conntrack
# Se repite la copia: asegura que dhcpd.conf e /etc/default/isc-dhcp-server
# son los nuestros aunque el paquete haya escrito los suyos al instalarse.
xj_instalar_arbol "$AQUI/rootfs"
systemctl daemon-reload

xj_paso "Registros en /var/log/xelaju (root:adm 0640)"
install -d -m 0750 -o root -g adm /var/log/xelaju
systemctl restart rsyslog
xj_ok "acl-lan.log (ACL) y dhcpd.log (DHCP) separados por rsyslog"

xj_paso "DHCP restringido de la VLAN 20 y conjunto MAC.IP de las ACL"
xelaju-dhcp aplicar
systemctl enable isc-dhcp-server >/dev/null 2>&1 || true
xelaju-dhcp verificar

xj_paso "Agente de Zabbix (modo activo, autorregistro 'xelaju-lan')"
xj_agente_zabbix R1-LAN xelaju-lan
if id zabbix >/dev/null 2>&1; then
    usermod -aG adm zabbix          # para leer /var/log/xelaju/*.log (items propios)
    systemctl restart zabbix-agent2 2>/dev/null || true
fi

xj_paso "Estado final"
r1-estado
xj_fin "R1-LAN en modo $MODO. Cambio de modo: sudo r1-modo individual|grupal"
