#!/bin/bash
# =============================================================================
# nodos/zbx-srv01/aplicar.sh - instala y configura (o restaura) ZBX-SRV01
#
# Servidor Zabbix 7.0 LTS con MariaDB y Apache, TODO por consola: base de
# datos, esquema, configuracion del servidor y de la interfaz web (sin pasar
# por el asistente web). La web queda restringida a la VLAN ADMIN en 3 capas.
# El monitoreo (grupos, autorregistro, equipos, items y dashboards) lo arma al
# final monitoreo.py por la API; docs/03-zabbix.md explica como se haria lo
# mismo desde la web.
#
# Necesita salida a Internet: R1-LAN en modo individual y SW-CORE01 listos.
# Uso, dentro de la VM:   sudo /mnt/proyecto/nodos/zbx-srv01/aplicar.sh
# Tarda entre 5 y 10 minutos la primera vez. Se puede repetir.
# =============================================================================
set -euo pipefail

NODO=zbx-srv01
AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
XJ_REPO="$(cd "$AQUI/../.." && pwd)"
. "$XJ_REPO/nodos/_comun/comun.sh"

ARCHIVO_CLAVE=/root/zabbix-db.txt
CONF_SERVIDOR=/etc/zabbix/zabbix_server.conf
CONF_WEB=/etc/zabbix/web/zabbix.conf.php
ESQUEMA=/usr/share/zabbix-sql-scripts/mysql/server.sql.gz
REG_SERVIDOR=/var/log/zabbix/zabbix_server.log

xj_requerir_root
xj_base "$NODO"

xj_paso "Red: IP estatica 192.168.30.10 en la VLAN 30"
xj_instalar "$AQUI/rootfs/etc/network/interfaces" /etc/network/interfaces
xj_resolv
xj_red_iniciar
if ! ping -c 2 -W 2 -q 192.168.30.1 >/dev/null; then
    xj_morir "no responde la puerta de enlace 192.168.30.1: revisa R1-LAN y SW-CORE01 (puerto p2)"
fi
xj_ok "puerta de enlace 192.168.30.1 alcanzable"

xj_paso "Paquetes: MariaDB, Zabbix 7.0 LTS (servidor, web, agente) y Apache"
if ! xj_hay_internet; then
    xj_morir "sin salida a Internet: R1-LAN debe estar en modo individual (sudo r1-modo estado)"
fi
xj_repo_zabbix || xj_morir "no se pudo agregar el repositorio oficial de Zabbix"
# apache2, libapache2-mod-php y php-mysql son dependencias de los paquetes de Zabbix;
# se nombran para que apt no elija otra alternativa (nginx, PostgreSQL).
xj_paquetes locales mariadb-server apache2 libapache2-mod-php php-mysql \
            zabbix-server-mysql zabbix-frontend-php zabbix-apache-conf zabbix-sql-scripts zabbix-agent2

xj_paso "Idiomas del sistema para la interfaz web (en_US y es_ES)"
sed -i -e 's/^# *\(en_US\.UTF-8 UTF-8\)/\1/' -e 's/^# *\(es_ES\.UTF-8 UTF-8\)/\1/' /etc/locale.gen
locale-gen >/dev/null
xj_ok "$(locale -a | grep -c -E '^(en_US|es_ES)\.utf8$') de 2 locales generados"

xj_paso "Base de datos 'zabbix' en MariaDB"
systemctl enable --now mariadb >/dev/null 2>&1
# La contrasena se genera una sola vez y se guarda solo para root
if [ -s "$ARCHIVO_CLAVE" ]; then
    CLAVE="$(sed -n 's/^clave=//p' "$ARCHIVO_CLAVE")"
else
    CLAVE="$(openssl rand -hex 16)"
    ( umask 077; printf 'base=zabbix\nusuario=zabbix\nclave=%s\n' "$CLAVE" > "$ARCHIVO_CLAVE" )
    xj_ok "contrasena generada y guardada en $ARCHIVO_CLAVE (0600)"
fi
if [ -z "$CLAVE" ]; then xj_morir "$ARCHIVO_CLAVE no contiene la clave"; fi

crear_base() {
    mariadb <<SQL
CREATE DATABASE IF NOT EXISTS zabbix CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;
CREATE USER IF NOT EXISTS 'zabbix'@'localhost' IDENTIFIED BY '$CLAVE';
ALTER USER 'zabbix'@'localhost' IDENTIFIED BY '$CLAVE';
GRANT ALL PRIVILEGES ON zabbix.* TO 'zabbix'@'localhost';
FLUSH PRIVILEGES;
SQL
}
crear_base

if [ ! -e "$XJ_ESTADO/zabbix-esquema" ]; then
    TABLAS="$(mariadb -N -B -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='zabbix'")"
    if [ "$TABLAS" -gt 0 ]; then
        xj_aviso "hay $TABLAS tablas de una importacion incompleta: se vacia la base y se repite"
        mariadb -e "DROP DATABASE zabbix"
        crear_base
    fi
    xj_ok "importando el esquema inicial (2 a 5 minutos, sin salida en pantalla)..."
    # El esquema crea funciones; con el registro binario activo MariaDB exige este permiso temporal
    mariadb -e "SET GLOBAL log_bin_trust_function_creators = 1"
    zcat "$ESQUEMA" | MYSQL_PWD="$CLAVE" mariadb --default-character-set=utf8mb4 -uzabbix zabbix
    mariadb -e "SET GLOBAL log_bin_trust_function_creators = 0"
    date > "$XJ_ESTADO/zabbix-esquema"
fi
xj_ok "base 'zabbix' con $(mariadb -N -B -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='zabbix'") tablas (utf8mb4 / utf8mb4_bin)"

xj_paso "Servidor Zabbix: conexion a la base de datos"
xj_conf "$CONF_SERVIDOR" DBPassword "$CLAVE"
chmod 0640 "$CONF_SERVIDOR"
chgrp zabbix "$CONF_SERVIDOR"

xj_paso "Interfaz web: $CONF_WEB escrito por consola (sin el asistente web)"
( umask 027
  sed "s|@@CLAVE@@|$CLAVE|" > "$CONF_WEB" <<'PHP'
<?php
// Configuracion de la interfaz web de Zabbix - generada por nodos/zbx-srv01/aplicar.sh
$DB['TYPE']           = 'MYSQL';
$DB['SERVER']         = 'localhost';
$DB['PORT']           = '0';
$DB['DATABASE']       = 'zabbix';
$DB['USER']           = 'zabbix';
$DB['PASSWORD']       = '@@CLAVE@@';
$DB['SCHEMA']         = '';
$DB['ENCRYPTION']     = false;
$DB['KEY_FILE']       = '';
$DB['CERT_FILE']      = '';
$DB['CA_FILE']        = '';
$DB['VERIFY_HOST']    = false;
$DB['CIPHER_LIST']    = '';
$DB['VAULT']          = '';
$DB['VAULT_URL']      = '';
$DB['VAULT_PREFIX']   = '';
$DB['VAULT_DB_PATH']  = '';
$DB['VAULT_TOKEN']    = '';
$DB['VAULT_CERT_FILE'] = '';
$DB['VAULT_KEY_FILE'] = '';
$DB['DOUBLE_IEEE754'] = true;

$ZBX_SERVER_NAME      = 'XelajuNetwork';
$IMAGE_FORMAT_DEFAULT = IMAGE_FORMAT_PNG;
PHP
)
chown root:www-data "$CONF_WEB"
chmod 0640 "$CONF_WEB"
xj_ok "zabbix.conf.php (root:www-data 0640)"

xj_paso "Apache: la web solo para la VLAN ADMIN (zz-xelaju-zabbix.conf)"
xj_instalar "$AQUI/rootfs/etc/apache2/conf-available/zz-xelaju-zabbix.conf" /etc/apache2/conf-available/zz-xelaju-zabbix.conf
# La ruta de la web debe ser la misma que usa el paquete de Zabbix
RUTA_WEB="$(awk '$1 == "Alias" && $2 == "/zabbix" { gsub(/"/, "", $3); print $3 }' /etc/zabbix/apache.conf 2>/dev/null | head -1)"
if [ -n "$RUTA_WEB" ] && [ "$RUTA_WEB" != /usr/share/zabbix ]; then
    sed -i "s|\"/usr/share/zabbix\"|\"$RUTA_WEB\"|" /etc/apache2/conf-available/zz-xelaju-zabbix.conf
    xj_aviso "la web de Zabbix esta en $RUTA_WEB: se ajusto zz-xelaju-zabbix.conf"
fi
a2enconf -q zz-xelaju-zabbix
apache2ctl configtest 2>&1 | sed 's/^/    /'

xj_paso "Cortafuegos del propio servidor (nftables)"
xj_instalar "$AQUI/rootfs/etc/nftables.conf" /etc/nftables.conf
nft -c -f /etc/nftables.conf
systemctl enable nftables >/dev/null 2>&1
systemctl restart nftables
xj_ok "tabla inet xelaju_zbx cargada: 80 solo ADMIN; 10051 SERVIDORES, GESTION y enlaces de transito del grupo"

xj_paso "Servicios"
systemctl enable zabbix-server apache2 >/dev/null 2>&1
systemctl restart zabbix-server apache2

# puerto_abierto <n>: espera hasta 40 s a que algo escuche en ese puerto TCP
puerto_abierto() {
    local i
    for i in $(seq 1 20); do
        if ss -Hltn "sport = :$1" | grep -q .; then return 0; fi
        sleep 2
    done
    return 1
}
if ! puerto_abierto 10051; then
    # Zabbix se niega a arrancar si la version de MariaDB no esta en su lista de
    # versiones probadas y lo dice en su registro junto al parametro que lo permite.
    if tail -n 60 "$REG_SERVIDOR" 2>/dev/null | grep -q 'AllowUnsupportedDBVersions'; then
        xj_aviso "esta version de MariaDB no figura como probada por Zabbix: se activa AllowUnsupportedDBVersions=1"
        xj_conf "$CONF_SERVIDOR" AllowUnsupportedDBVersions 1
        systemctl restart zabbix-server
        puerto_abierto 10051 || xj_morir "zabbix-server no arranca: revisa $REG_SERVIDOR"
    else
        xj_morir "zabbix-server no escucha en 10051: revisa $REG_SERVIDOR"
    fi
fi
xj_ok "zabbix-server escuchando en TCP 10051"

xj_paso "Agente de Zabbix del propio servidor"
# El host "Zabbix server" ya existe en la base inicial y se consulta por 127.0.0.1
xj_agente_zabbix "Zabbix server" xelaju-zbx 127.0.0.1

xj_paso "Comprobacion de la restriccion de la web"
LOCAL="$(curl -s -o /dev/null -m 15 -w '%{http_code}' http://127.0.0.1/zabbix/ || true)"
AJENA="$(curl -s -o /dev/null -m 15 -w '%{http_code}' http://192.168.30.10/zabbix/ || true)"
if [ "$LOCAL" = 200 ]; then xj_ok "desde 127.0.0.1: HTTP 200 (la web funciona)"
else xj_aviso "desde 127.0.0.1 se esperaba 200 y se obtuvo $LOCAL: revisa /var/log/apache2/error.log"; fi
if [ "$AJENA" = 403 ]; then xj_ok "desde 192.168.30.10 (fuera de ADMIN): HTTP 403 (Apache la niega)"
else xj_aviso "desde una IP que no es de ADMIN se esperaba 403 y se obtuvo $AJENA"; fi

xj_paso "Monitoreo por la API: grupos, autorregistro, equipos, items y dashboards (monitoreo.py)"
# La API se atiende en 127.0.0.1. Espera hasta 90 s a que R1-LAN se registre
# solo (su agente pregunta al servidor cada pocos segundos). Codigo 2 = todo
# creado salvo lo que depende de R1-LAN: basta repetir monitoreo.py despues.
RC_MON=0
# -u: sin bufer de salida, para ver cada linea en el momento aunque vaya a un registro
python3 -u "$AQUI/monitoreo.py" --esperar 90 || RC_MON=$?
case "$RC_MON" in
    0) xj_ok "monitoreo configurado" ;;
    2) xj_aviso "falta lo que depende de R1-LAN: repite  sudo $AQUI/monitoreo.py  cuando su agente este en marcha" ;;
    *) xj_aviso "monitoreo.py termino con error $RC_MON (si cambiaste la clave de Admin: monitoreo.py --clave <clave>)" ;;
esac

xj_fin "ZBX-SRV01. Abre http://192.168.30.10/zabbix desde PC-ADMIN01 (usuario Admin, clave zabbix: cambiala; docs/03-zabbix.md)"
