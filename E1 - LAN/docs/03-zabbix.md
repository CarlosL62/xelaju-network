# 03 — Zabbix (ZBX-SRV01, 192.168.30.10)

El enunciado separa dos cosas:

- **Instalación y configuración del servicio: por consola.** La hace `nodos/zbx-srv01/aplicar.sh` (base de datos, esquema, `zabbix_server.conf`, `zabbix.conf.php`, Apache, nftables). No se usa el asistente web.
- **Monitoreo: la web es para verlo y administrarlo.** Grupos, autorregistro, equipos, items y dashboards los crea `nodos/zbx-srv01/monitoreo.py` por la API de Zabbix (lo llama `aplicar.sh` al final; se puede repetir). Las secciones 4 a 9 explican **qué crea y cómo se haría lo mismo a mano desde la web**, para poder revisarlo, cambiarlo y defenderlo.

Los nombres de menú corresponden a Zabbix 7.0 en inglés; la sección 3 dice dónde cambiar el idioma.

```bash
sudo /mnt/proyecto/nodos/zbx-srv01/monitoreo.py                  # dentro de ZBX-SRV01
sudo /mnt/proyecto/nodos/zbx-srv01/monitoreo.py --clave <clave>  # si ya cambiaste la contraseña de Admin
```

La API es JSON-RPC sobre HTTP y solo se atiende en 127.0.0.1 y desde la VLAN ADMIN (las mismas tres capas que la web).

## 1. Qué instala el script

| Componente | Detalle |
|---|---|
| Zabbix | 7.0 LTS, del repositorio oficial `repo.zabbix.com/zabbix/7.0/debian` (paquete `zabbix-release` para Debian 13) |
| Paquetes | `zabbix-server-mysql`, `zabbix-frontend-php`, `zabbix-apache-conf`, `zabbix-sql-scripts`, `zabbix-agent2` |
| Base de datos | MariaDB 11.8; base `zabbix` en `utf8mb4` / `utf8mb4_bin`; usuario `zabbix`@localhost |
| Contraseña de la base | Generada con `openssl rand`, guardada en `/root/zabbix-db.txt` (0600) |
| Esquema | `/usr/share/zabbix-sql-scripts/mysql/server.sql.gz`, importado con el cliente `mariadb` |
| Web | Apache + PHP; `/etc/zabbix/web/zabbix.conf.php` escrito por el script |
| Idioma y hora | Locales `en_US.UTF-8` y `es_ES.UTF-8`; zona `America/Guatemala` |

## 2. Restricción a la VLAN ADMIN (3 capas)

| Capa | Dónde | Regla |
|---|---|---|
| 1 | R1-LAN, `30-acl.nft` | Solo la VLAN ADMIN puede abrir conexiones a 192.168.30.10:80. A USUARIOS se le niega todo lo que no sea la Intranet; a GESTIÓN, y a todo lo que llega del perímetro (también los clientes VPN), una regla expresa les niega la web de Zabbix; a los enlaces de tránsito del grupo solo se les acepta TCP 10051 |
| 2 | ZBX-SRV01, `/etc/nftables.conf` | `ip saddr 192.168.10.0/24 tcp dport 80 accept`; el resto de orígenes cae en la política `drop` |
| 3 | Apache, `zz-xelaju-zabbix.conf` | `Require ip 192.168.10.0/24 127.0.0.1` → 403 a cualquier otro |

Comprobación rápida:

| Desde | Orden | Resultado |
|---|---|---|
| PC-ADMIN01 | `curl -s -o /dev/null -w '%{http_code}\n' http://192.168.30.10/zabbix/` | `200` |
| PC-USER01, PC-MGMT01 | la misma | sin respuesta (tiempo agotado) |
| El propio ZBX-SRV01 | `curl ... http://192.168.30.10/zabbix/` | `403` (capa 3: su IP no es de ADMIN) |

Puertos de Zabbix: **10051** es donde el servidor recibe a los agentes activos (se acepta desde SERVIDORES, GESTIÓN y los enlaces de tránsito del grupo, 192.168.81–84.0/30); **10050** es donde un agente atiende consultas pasivas del servidor.

## 3. Primer acceso

En PC-ADMIN01, Firefox → `http://192.168.30.10/zabbix`

1. Usuario `Admin`, contraseña `zabbix`.
2. **Cambiar la contraseña**: *Users → Users → Admin → Change password*.
3. Idioma (opcional): *User settings → Profile → Language → Spanish (es_ES)*.
4. Comprobar que el usuario `guest` está deshabilitado: *Users → Users → guest* debe pertenecer al grupo *Disabled* (en 7.0 viene así).
5. *Monitoring → Hosts*: el host `Zabbix server` debe tener el indicador **ZBX** en verde a los pocos minutos.

## 4. Grupos de hosts

*Data collection → Host groups → Create host group*:

- `XelajuNetwork/LAN`
- `XelajuNetwork/Multi-WAN`

## 5. Autorregistro

Los agentes de la LAN están en modo activo y envían un texto (`HostMetadata=xelaju-lan`) al conectarse. Con una acción, los equipos aparecen solos.

*Alerts → Actions → Autoregistration actions → Create action*

| Acción | Condición | Operaciones |
|---|---|---|
| `Autorregistro LAN` | *Host metadata* **contains** `xelaju-lan` | *Add host*; *Add to host groups*: `XelajuNetwork/LAN`; *Link templates*: `Linux by Zabbix agent active` |

Comprobado en el laboratorio: aunque los agentes arranquen antes de que exista la acción (R1 y los switches se configuran antes que el servidor), se registran solos a los pocos segundos de crearla, porque cada agente vuelve a preguntar al servidor qué debe medir. Si alguno no apareciera: `sudo systemctl restart zabbix-agent2` en ese nodo (desde el host: `./lab/lab.sh exec r1-lan systemctl restart zabbix-agent2`).

Hosts que deben aparecer en *Data collection → Hosts*:

| Host | Equipo | Origen de la conexión | Cómo se da de alta |
|---|---|---|---|
| `R1-LAN` | router | 192.168.30.1 | autorregistro |
| `SW-CORE01` | switch de núcleo | 192.168.40.2 | autorregistro |
| `SW-ACC01` | switch de acceso | 192.168.40.3 | autorregistro |
| `SRV-INTRA01` | Intranet | 192.168.30.20 | autorregistro |
| `Router-MultiWAN-E3` | Multi-WAN del Est. 3 (modo grupal) | 192.168.81.1 | a mano (sección 8) |

La plantilla descubre sola las interfaces de red: en R1 aparecen `trunk0.10` … `trunk0.40` (tráfico por VLAN) y en los switches `p0` … `p5` (tráfico por puerto).

## 6. Hosts por ping (los PC)

Los PC no llevan agente; se vigila que respondan. Las ACL de R1 solo dejan a Zabbix hacer ping hacia las VLAN de clientes.

*Data collection → Hosts → Create host*, uno por PC:

| Host name | Templates | Host groups | Interfaces → Agent → IP |
|---|---|---|---|
| `PC-ADMIN01` | `ICMP Ping` | `XelajuNetwork/LAN` | 192.168.10.50 |
| `PC-USER01` | `ICMP Ping` | `XelajuNetwork/LAN` | 192.168.20.10 |
| `PC-USER02` | `ICMP Ping` | `XelajuNetwork/LAN` | 192.168.20.11 |
| `PC-MGMT01` | `ICMP Ping` | `XelajuNetwork/LAN` | 192.168.40.10 |

La interfaz se añade solo para indicar la IP: la plantilla `ICMP Ping` hace el ping desde el servidor.

## 7. Items propios de R1-LAN

R1 publica cuatro métricas con `UserParameter` (`/etc/zabbix/zabbix_agent2.d/xelaju-r1.conf`).

*Data collection → Hosts → R1-LAN → Items → Create item*, cuatro veces:

| Name | Type | Key | Type of information | Update interval |
|---|---|---|---|---|
| Equipos registrados (DHCP) | Zabbix agent (active) | `xelaju.dhcp.registrados` | Numeric (unsigned) | 1m |
| DHCP: concesiones (DHCPACK) | Zabbix agent (active) | `xelaju.dhcp.ack` | Numeric (unsigned) | 1m |
| DHCP: rechazos a no registrados | Zabbix agent (active) | `xelaju.dhcp.rechazos` | Numeric (unsigned) | 1m |
| ACL: paquetes bloqueados | Zabbix agent (active) | `xelaju.acl.bloqueos` | Numeric (unsigned) | 1m |

Comprobar antes desde R1 que devuelven un número:

```bash
sudo -u zabbix /usr/local/sbin/xelaju-metrica registrados
zabbix_agent2 -t xelaju.acl.bloqueos
```

Los tres contadores de registro cuentan líneas del archivo actual; vuelven a cero con la rotación semanal.

## 8. Multi-WAN del Estudiante 3

El enunciado pide ver en Zabbix el tráfico de entrada y de salida de ISP1 e ISP2. Esos contadores viven en el equipo de E3, así que la mitad del trabajo es suya y la otra mitad es de este servidor.

**Lo que publica E3** (su script `zabbix_agent_multiwan.sh`): su agente se identifica como `Hostname=Router-MultiWAN-E3`, apunta a `ServerActive=192.168.30.10` y define ocho `UserParameter` que leen los contadores del kernel en `/sys/class/net/<interfaz>/statistics/`:

| Clave | Qué devuelve |
|---|---|
| `multiwan.isp1.rx_bytes`, `multiwan.isp1.tx_bytes` | bytes recibidos y enviados por la interfaz de ISP1 desde que se levantó |
| `multiwan.isp1.rx_packets`, `multiwan.isp1.tx_packets` | paquetes recibidos y enviados por ISP1 |
| `multiwan.isp2.*` | lo mismo para ISP2 |

Su agente no envía `HostMetadata`, así que no puede usar el autorregistro: el equipo se da de alta en el servidor **con el mismo nombre** que el agente usa en `Hostname`. Cuando el agente pregunta "¿qué debo medir para `Router-MultiWAN-E3`?", el servidor le contesta con los items de abajo.

**Lo que crea este servidor** (`monitoreo.py`; a mano: *Data collection → Hosts → Create host* y después *Items → Create item*):

| Campo | Valor |
|---|---|
| Host name | `Router-MultiWAN-E3` |
| Host groups | `XelajuNetwork/Multi-WAN` |
| Interface (Agent) | 192.168.81.1 (solo informativa: los items son activos) |

| Item | Key | Unidad | Preprocesado |
|---|---|---|---|
| ISP1 entrada | `multiwan.isp1.rx_bytes` | bps | *Change per second* y *Custom multiplier* 8 |
| ISP1 salida | `multiwan.isp1.tx_bytes` | bps | *Change per second* y *Custom multiplier* 8 |
| ISP1 paquetes de entrada | `multiwan.isp1.rx_packets` | pps | *Change per second* |
| ISP1 paquetes de salida | `multiwan.isp1.tx_packets` | pps | *Change per second* |
| ISP2 … (los mismos cuatro) | `multiwan.isp2.*` | | |

Todos: *Type* `Zabbix agent (active)`, *Type of information* `Numeric (float)`, *Update interval* 30s.

**Por qué el preprocesado.** La clave entrega un contador que solo crece (por ejemplo 81 234 567 bytes). *Change per second* guarda la diferencia con la muestra anterior dividida entre los segundos transcurridos: bytes por segundo. Multiplicado por 8 son bits por segundo, que es como se mide un enlace. Sin preprocesado, la gráfica sería una rampa que nunca baja.

**Camino de los datos:** E3 (192.168.81.1) → E5 → E2 → R1 → 192.168.30.10, TCP 10051. Lo tienen que permitir E5 (firewall), R1 (`desde_perimetro`, orígenes `REDES_TRANSITO`) y el cortafuegos del propio servidor.

Mientras el agente de E3 no llegue al servidor, el equipo existe pero **no tiene datos** (*Latest data* vacío). Para comprobarlo cuando llegue:

```bash
# en E3
nc -zv -w 4 192.168.30.10 10051
# en ZBX-SRV01
sudo grep -i 'Router-MultiWAN' /var/log/zabbix/zabbix_server.log | tail
```

Si E3 cambia el `Hostname` o una clave, se cambia lo mismo en `EQUIPO_WAN` e `ITEMS_WAN` de `monitoreo.py`.

## 9. Dashboards

*Dashboards → Create dashboard*. `monitoreo.py` crea los dos y, si ya existen, los deja como dice el script.

### "LAN - Estudiante 1"

| Widget | Tipo | Contenido |
|---|---|---|
| Tráfico por VLAN | Graph | Host `R1-LAN`, items `Interface trunk0.*: Bits received` y `Bits sent` (las cuatro subinterfaces) |
| Tráfico de la troncal | Graph | Host `SW-CORE01`, `Interface p0: Bits received/sent` |
| Disponibilidad | Host availability | Grupo `XelajuNetwork/LAN` |
| Problemas | Problems | Grupo `XelajuNetwork/LAN` |
| Equipos registrados, concesiones y rechazos DHCP, bloqueos de las ACL | Item value | Los cuatro items propios de `R1-LAN` |
| Bloqueos de las ACL y rechazos DHCP | Graph | `R1-LAN: ACL: paquetes bloqueados` y `DHCP: rechazos a no registrados` |

Los items `Interface …` no existen hasta que la plantilla descubre las interfaces de cada equipo (regla *Network interface discovery*, clave `net.if.discovery`). De fábrica esa regla se ejecuta una vez por hora; `monitoreo.py` la deja en 5 minutos (*Data collection → Templates → Linux by Zabbix agent active → Discovery → Network interface discovery → Update interval*) para que las gráficas de tráfico aparezcan pronto. Hasta entonces esas dos gráficas salen vacías.

### "Multi-WAN - Estudiante 3"

| Widget | Tipo | Contenido |
|---|---|---|
| ISP1: entrada y salida | Graph | Host `Multi-WAN (Estudiante 3)` (el nombre visible de `Router-MultiWAN-E3`: las gráficas eligen el equipo por ese nombre), items `ISP1 entrada` e `ISP1 salida` |
| ISP2: entrada y salida | Graph | Host `Multi-WAN (Estudiante 3)`, items `ISP2 entrada` e `ISP2 salida` |
| Valor actual de cada sentido | Item value (4) | `ISP1 entrada`, `ISP1 salida`, `ISP2 entrada`, `ISP2 salida` |
| Paquetes por segundo | Graph | Los cuatro items de paquetes |
| Disponibilidad y problemas | Host availability, Problems | Grupo `XelajuNetwork/Multi-WAN` |

## 10. Comprobaciones por consola en ZBX-SRV01

| Qué | Orden |
|---|---|
| Servicios | `systemctl is-active mariadb zabbix-server apache2 zabbix-agent2 nftables` |
| Puertos | `sudo ss -ltnp \| grep -E ':(80\|10051\|10050)\b'` |
| Registro del servidor | `sudo tail -30 /var/log/zabbix/zabbix_server.log` |
| Cortafuegos propio | `sudo nft list table inet xelaju_zbx` (contadores por regla) |
| Agentes que conectan | `sudo grep -i 'active check' /var/log/zabbix/zabbix_server.log \| tail` |
| Base de datos | `sudo mariadb -e "SELECT COUNT(*) FROM zabbix.hosts WHERE status=0"` |

## 11. Preguntas probables

- **¿Por qué agentes activos?** El agente abre la conexión hacia el servidor (TCP 10051). En las ACL basta permitir ese sentido; el servidor no necesita poder entrar a cada VLAN. Además permite el autorregistro.
- **¿Por qué la web solo desde ADMIN, y en tres capas?** Defensa en profundidad: si una capa se desconfigura, quedan dos. Cada una se puede demostrar por separado (bloqueo en R1, contador de nftables en ZBX, 403 de Apache).
- **¿Cómo llegan las métricas del Multi-WAN si está fuera de la LAN?** Su agente se conecta a 192.168.30.10:10051 pasando por el firewall y por Squid; R1 lo permite solo desde los enlaces de tránsito del grupo y solo a ese puerto, y el nftables de ZBX también.
- **¿Por qué el monitoreo se arma con un script y no a mano en la web?** Porque así es repetible: si el servidor se reinstala, queda igual en un minuto. El script usa la misma API que usa la web; cada llamada equivale a un formulario de los que describe esta guía.
- **¿Por qué el Multi-WAN no se autorregistra como los equipos de la LAN?** Porque el autorregistro se decide por el `HostMetadata` que envía el agente, y el de E3 no lo envía. Basta con que el equipo exista en el servidor con el mismo nombre que su `Hostname`.
- **¿Qué pasa si se pierde la contraseña de la base?** Está en `/root/zabbix-db.txt`; `aplicar.sh` la reutiliza y vuelve a escribir los dos archivos de configuración.
