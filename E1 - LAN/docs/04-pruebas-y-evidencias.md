# 04 — Pruebas y evidencias

Tres niveles de prueba, del más barato al más completo:

| Nivel | Qué prueba | Cómo | Necesita VMs |
|---|---|---|---|
| 1. Estático | Sintaxis, reglas cargables, coherencia de datos | `./pruebas/validar-estatico.sh` | No |
| 2. Ensayo | VLAN, enrutamiento y ACL con tráfico real, en namespaces | `./pruebas/simular-lan.sh [grupal]` | No |
| 3. Laboratorio | Todo, incluido DHCP, Zabbix y capturas | `./lab/lab.sh probar` y demostraciones | Sí |

Regla aprendida en el Proyecto 1: cada resultado se respalda con **captura de pantalla y salida de consola**, y lo que no funcionó a la primera se anota en `07-problemas-y-soluciones.md`.

## 1. Resultados obtenidos

Ejecutados el 3 de octubre de 2026 en el host Debian, con el componente ya adaptado a `core/` y a los ADR del grupo:

| Prueba | Resultado |
|---|---|
| `validar-estatico.sh` | 27 scripts sin errores de sintaxis; reglas de R1 cargadas en el kernel en ambos modos (54 y 53 reglas con contador); NAT solo en modo individual; 97 comprobaciones de coherencia correctas, 10 de ellas contra `core/ADDRESSING.yaml` |
| `simular-lan.sh individual` | 61 PASS, 0 FAIL, 2 omitidas (DHCP) + 7 comprobaciones adicionales correctas |
| `simular-lan.sh grupal` | 93 PASS, 0 FAIL, 2 omitidas (DHCP) + 20 comprobaciones adicionales correctas, entre ellas las de la frontera E1/E5 |
| `lab.sh probar` (en las 10 VMs) | 6 perfiles, 63 casos: **63 PASS, 0 FAIL**, ninguna omitida (aquí el DHCP sí es real) |
| Web de Zabbix | 200 desde PC-ADMIN01; sin respuesta desde PC-USER01 y PC-MGMT01; 403 desde el propio servidor |
| `monitoreo.py` contra el servidor real | Terminó con "monitoreo configurado": R1-LAN, SW-CORE01, SW-ACC01 y SRV-INTRA01 se registraron solos; `Router-MultiWAN-E3` con sus 8 items; dos dashboards |
| Cambio de modo en la VM de R1 | `r1-modo grupal`: 192.168.84.2/30, ruta por defecto vía 192.168.84.1, 0 cadenas de NAT; `r1-modo individual`: vuelve la salida y el NAT |
| Persistencia | R1 y SW-CORE01 reiniciados: VLAN, rutas, ACL, DHCP y espejo vuelven solos; `lab.sh probar` repetido después: 63 PASS |
| Capturas de tráfico (`evidencias/pcap/`) | Troncal: 904 tramas, todas con etiqueta (VLAN 10, 20, 30 y 40) y ninguna sin ella; puerto de acceso de la VLAN 10: 254 tramas, ninguna etiquetada; espejo p5: copia de la troncal con etiquetas; DHCP de PC-USER02: Release, Discover, Offer, Request, ACK con 192.168.20.11; PC-INTRUSO: dos Discover y ninguna oferta; ping de PC-USER02 a 192.168.10.50: 4 peticiones, 0 respuestas |

Dónde está cada resultado:

| Archivo | Contenido |
|---|---|
| `evidencias/simulacion/` | Detalle de los dos ensayos sin VMs |
| `evidencias/pruebas/` | Un archivo por perfil y el resumen de `lab.sh probar` |
| `evidencias/consola/<vm>-aplicar.log` | Salida completa de `aplicar.sh` de cada equipo |
| `evidencias/consola/r1-lan-cambio-de-modo.log` | Cambio de modo en R1 |
| `evidencias/consola/verificacion-zabbix-dhcp-acl.log` | Restricción de la web de Zabbix, DORA de los equipos registrados, rechazo al intruso y bloqueos de las ACL |
| `evidencias/consola/persistencia-tras-reinicio.log` | R1 y SW-CORE01 recién reiniciados, sin ejecutar nada |
| `evidencias/consola/integracion-grupal-e2-e5-e3.log` | Integración real del 4 de octubre: puente del host, R1 en modo grupal, pruebas hacia Internet por E2, E5 y E3 |
| `evidencias/consola/integracion-grupal-squid-dmz-isp.log` | Segunda ronda del 4 de octubre: Squid desde cada VLAN, portal, LAN → WEB01, ISP en uso y Zabbix |
| `evidencias/consola/integracion-grupal-failover-isp.log` | Tercera ronda del 4 de octubre: cambios de estado durante el failover real, pruebas con el ISP1 desconectado, Squid, LAN → WEB01 y Zabbix |
| `evidencias/consola/vpn-llegadas-r1-20261010.log` | Llegadas por VPN registradas en R1 (matriz de E4 del 10 de octubre) y negación de la web de Zabbix |
| `evidencias/consola/isp-activo-AAAAMMDD.log` | Registro de `grupal/isp-activo.sh`: una línea por ciclo con el ISP de cada clase de tráfico |
| `evidencias/pcap/*.pcap` | Capturas para abrir en Wireshark (sección 5) |

### Integración real con el grupo (4 de octubre de 2026)

Primera prueba con los equipos de los compañeros conectados por cable: la tarjeta del host en puente con la VM de R1 (`uplinks-host.sh up --squid enp7s0`) y R1 en modo grupal. Salida completa en `evidencias/consola/integracion-grupal-e2-e5-e3.log`.

| Prueba | Desde | Resultado |
|---|---|---|
| Ruta por defecto de R1 | R1 | `default via 192.168.84.1 dev up-squid`; 0 cadenas de NAT |
| Ping al vecino | R1 y las VLAN 10, 20 y 30 | Responde E2 (`192.168.84.1`): E2 tiene las rutas de vuelta a las VLAN |
| HTTPS a Internet con origen en la VLAN 20 | R1 (`--interface 192.168.20.1`) y PC-USER01 | `301` de `https://1.1.1.1` |
| HTTPS a Internet | PC-ADMIN01 y ZBX-SRV01 | `301` |
| Camino completo | R1, `traceroute -T -p 443 -s 192.168.20.1 1.1.1.1` | Saltos `192.168.84.1` (E2) → `192.168.82.1` (E5) → `192.168.81.1` (E3) → red del ISP |
| DNS | R1 y PC-USER01 | Responde por UDP y por TCP |
| HTTP (puerto 80) | PC-ADMIN01, PC-USER01, ZBX-SRV01 | **Rechazado.** En E2 el puerto 3128 de Squid está abierto y el 3129 (intercepción) cerrado. Pendiente de E2 |
| LAN → WEB01 de la DMZ (TCP 8081) | PC-ADMIN01, PC-USER01, ZBX-SRV01 | **Rechazado.** Pendiente de E4 |
| GESTIÓN → WEB01 | PC-MGMT01 | Bloqueado por R1, como debe |
| LAN → DMZ por otro puerto (22) | PC-USER01 | Bloqueado |
| Métricas del Multi-WAN en Zabbix | ZBX-SRV01 | **Sin datos:** el agente de E3 todavía no ha contactado con el servidor |
| VPN → LAN | — | **Sin probar** |

Lo que demuestra esta parte: R1 no hace NAT (los compañeros ven las direcciones reales de cada VLAN) y basta su ruta por defecto para alcanzar Internet a través de tres equipos ajenos.

Dos cosas que conviene saber al repetirlo:

- Las pruebas se lanzan **dentro de R1 o de una VM**. Desde la terminal del host no funcionan: el host no tiene dirección en el enlace, solo hace de puente.
- El firewall de E5 no reenvía ping ni contesta a la LAN. Para comprobar el camino se usa `traceroute -T -p 443`, no `ping`.

### Segunda ronda con el grupo (4 de octubre, noche)

Después de los cambios de E2. Salida completa en `evidencias/consola/integracion-grupal-squid-dmz-isp.log`; perfiles en `evidencias/pruebas/*-20261004-21*.txt`.

| Prueba | Resultado |
|---|---|
| `lab.sh probar` con R1 en modo grupal | **63 PASS, 0 FAIL**: los casos `internet` (HTTP, ahora por Squid) ya pasan |
| `validar-estatico.sh` y `simular-lan.sh grupal` | Correcta; 93 PASS, 0 FAIL, 2 omitidas |
| Intercepción de Squid | El HTTP de las VLAN 10, 20, 30 y 40 vuelve con la cabecera `Via: … squid`; el HTTPS sale directo |
| Listas negras por VLAN (solo HTTP) | ADMIN: facebook e ilovepdf `403`, youtube pasa. USUARIOS: facebook y youtube `403`, ilovepdf pasa. SERVIDORES y GESTIÓN: sin lista. Por HTTPS no se filtra nada |
| Portal de E2 (`192.168.84.1:8080`) | `200` desde la VLAN ADMIN; `403` desde USUARIOS y SERVIDORES; GESTIÓN no llega (R1 solo le deja salir por 53, 80 y 443) |
| Sin NAT en R1 | El registro de Squid muestra `192.168.10.50`, `192.168.20.10`, `192.168.20.11`, `192.168.30.10` y `192.168.40.10` |
| Perfiles `g-*` de la matriz grupal | 3 PASS y 3 FAIL: GL2, GL3 y GL6, los tres de LAN → WEB01 |
| LAN → WEB01 (TCP 8081) | **No llega.** No es un rechazo de WEB01: E5 (`192.168.82.1`) responde ICMP "host unreachable" 3 s después del primer SYN. Deducción de E1: E5 no alcanza a E4 (`192.168.83.2`). Pedida la confirmación a E5 |
| ISP en uso (`grupal/isp-activo.sh`) | Con los dos ISP activos: TCP 443 de ADMIN y USUARIOS por ISP1; TCP 443 de SERVIDORES y DNS de USUARIOS por ISP2; el resto (DNS de ADMIN, SERVIDORES y GESTIÓN, y TCP 443 de GESTIÓN) balanceado. Coincide con `policies.txt` de E3 |
| Métricas del Multi-WAN en Zabbix | **Sin datos:** a R1 no ha llegado ningún paquete hacia el 10051 desde los enlaces de tránsito |
| VPN → LAN | **Sin probar** |

Dos avisos sobre esta ronda:

- En esta ronda los estados de failover de `isp-activo.sh` (`SOLO-ISP1`, `SOLO-ISP2`) solo se habían probado con sondas simuladas. La prueba real es la tercera ronda, más abajo.
- Al final de la sesión (21:33–21:37) fallaron conexiones de forma intermitente y E2 dejó de responder en el enlace. Está en el punto 6 de ese registro y en `07-problemas-y-soluciones.md`, sección 3.

### Tercera ronda: failover real del Multi-WAN (4 de octubre, 22:38–23:05)

E3 desconectó y reconectó cada ISP mientras `grupal/isp-activo.sh` registraba desde R1. Resumen en `evidencias/consola/integracion-grupal-failover-isp.log`; ciclo a ciclo en `evidencias/consola/isp-activo-20261004.log`.

| Hora | Lo que registró el monitor |
|---|---|
| 22:40:57 | `NORMAL → SOLO-ISP2`: cae el ISP1 y las 8 clases salen por el ISP2, con conexión correcta |
| 22:42:15 | `SOLO-ISP2 → SIN-SALIDA`: sin ningún ISP, E3 contesta "sin ruta" y todo falla, como debe |
| 22:43:25 | Vuelta a `NORMAL`: cada clase regresa a su ISP |
| 22:46:49 | `NORMAL → SOLO-ISP1`: cae el ISP2 y todo sale por el ISP1 |
| 22:47–22:50 | Varias caídas y vueltas seguidas de uno y otro ISP; el estado las sigue en uno o dos ciclos |
| 22:50:16 en adelante | `SOLO-ISP2` sostenido (ISP1 desconectado) hasta el final de la prueba |

| Comprobación | Resultado |
|---|---|
| Conexiones reales con todo por el ISP2 (`SOLO-ISP2`, 102 ciclos) | 815 correctas, 1 fallida; incluye el DNS por UDP |
| Conexiones reales con todo por el ISP1 (`SOLO-ISP1`, 7 ciclos) | 56 correctas, 0 fallidas |
| Sin ningún ISP (`SIN-SALIDA`, 3 ciclos) | 24 fallidas de 24 |
| `lab.sh probar` con el ISP1 desconectado | **63 PASS, 0 FAIL** |
| Squid con el ISP1 desconectado | Intercepción, listas por VLAN y portal igual que en la segunda ronda |
| LAN → WEB01 (TCP 8081) a las 23:23 | **Ya llega**: `200` desde PC-ADMIN01, PC-USER01 y ZBX-SRV01; PC-MGMT01 bloqueado por R1 (`ACL-DENY MGMT->?`), como debe. Los 6 casos `g-*` pasan. Lo que cambió desde las 23:05 no se ve desde E1 |
| LAN → WEB01 (TCP 8081) a las 23:05 | Todavía no llegaba: E5 respondía "host unreachable" a los 3 s. E5 anotó a las 21:56 que E4 salía a Internet por su firewall, así que el enlace E5–E4 funcionaba entonces; la causa está por ver en E5 |
| Métricas del Multi-WAN en Zabbix | **Sin datos**: llegó 1 paquete al 10051 desde un enlace de tránsito (parece una prueba de puerto) y ninguna muestra |

La prueba destapó un fallo del propio monitor: durante un ciclo marcó `NORMAL` (22:42:41 y 22:47:32) cuando una referencia ya salía y para la otra E3 aún contestaba "sin ruta". Está corregido: ese caso ahora es `PARCIAL`.

### Cuarta ronda: VPN y estado tras reiniciar el host (10 de octubre)

| Prueba | Resultado |
|---|---|
| Arranque tras reiniciar el host | Las 10 VMs levantan con su configuración. El puente del host no sobrevive al reinicio: hubo que repetir `uplinks-host.sh up`, reiniciar R1 y `r1-modo grupal`. Antes de eso, `lab.sh probar` dio 58 PASS y 5 FAIL, los cinco casos `internet` |
| VPN-ADMIN → LAN (16:56) | R1 dejó pasar y registró: ping a PC-ADMIN01, SSH a PC-USER01, ping a Zabbix, HTTP a la Intranet y SSH a SW-CORE01, con origen `10.200.10.10` |
| VPN-USERS → LAN (16:56) | R1 dejó pasar y registró: ping a PC-USER01 y HTTP y HTTPS a la Intranet, con origen `10.200.20.10`. Nada más llegó a R1: el resto lo corta E5 |
| Web de Zabbix por VPN | Negada en R1: 6 paquetes de `10.200.10.10` en `ACL-DENY PERIMETRO->ZBXWEB` |
| LAN → WEB01 (17:20) | `200` desde PC-ADMIN01 |
| ISP en uso | `NORMAL`. El ISP2 sale hoy por otra puerta (`172.20.10.1`); `isp-activo.sh` la aprendió solo. El ISP1 estuvo inestable: 5 caídas en 1 h 40 min |
| `lab.sh probar` en modo grupal | 60 PASS y 3 FAIL a las 19:30 (casos `internet`, por los cortes del ISP1); **63 PASS** a las 20:31 |
| Perfiles `g-*` (20:18, con E4 conectado) | Los 6 PASS |
| Métricas del Multi-WAN en Zabbix (22:36) | **Llegan**: los 8 items del agente de E3, con origen `192.168.81.1`. El ISP2 marcaba 0 bps porque en ese momento estaba desconectado (`SOLO-ISP1` en el monitor) |

Al llegar los datos se vio que las gráficas del dashboard del Multi-WAN seguían vacías: `monitoreo.py` las asociaba al nombre del agente y Zabbix elige el equipo por su nombre visible. Corregido y reaplicado; los valores sueltos sí se mostraban.

Evidencia: `evidencias/consola/vpn-llegadas-r1-20261010.log`. R1 no decide la política VPN (lo hace E5); lo que demuestra este registro es que el tráfico autorizado llega a cada VLAN con su dirección de la VPN y que R1 mantiene cerrada la web de Zabbix.

Una versión anterior del diseño se sometió a una prueba de mutación (dos reglas estropeadas a propósito: sin binding MAC·IP y USUARIOS→ADMIN permitido) y el ensayo marcó 6 FAIL: las pruebas sí detectan una ACL rota.

Las capturas de pantalla están en `evidencias/capturas/`: 37, del 10 de octubre, de consola, del navegador (Zabbix, Intranet, portal de Squid, WEB01) y de Wireshark. La lista, con lo que muestra cada una, está en `evidencias/README.md`.

Lo que **falta**: repetir las demostraciones de la sección 3 hasta poder explicarlas, y una captura del Multi-WAN con los dos ISP llevando tráfico a la vez.

## 2. Matriz de pruebas (nivel 3)

`pruebas/matriz.conf` tiene 63 casos en 6 perfiles. Cada perfil se ejecuta dentro de un equipo:

| Perfil | Equipo | Casos | Qué demuestra |
|---|---|---|---|
| `admin` | PC-ADMIN01 | 12 | ADMIN llega a todo: puertas de enlace, usuarios, servidores, web de Zabbix (200), SSH de switches y R1, Internet |
| `users` | PC-USER01 | 15 | IP reservada por DHCP y misma IP al renovar; ADMIN y GESTIÓN bloqueados; Intranet 80/443 permitida; ping/SSH a servidores y web de Zabbix bloqueados; Internet |
| `users2` | PC-USER02 | 4 | Segunda reserva (.11) con las mismas restricciones |
| `intruso` | PC-INTRUSO | 11 | DHCP sin oferta; con IP puesta a mano, todo bloqueado; con la IP de un equipo registrado pero otra MAC, bloqueado |
| `mgmt` | PC-MGMT01 | 10 | SSH a R1 y a servidores permitido; web de Zabbix, ADMIN y USUARIOS bloqueados |
| `zbx` | ZBX-SRV01 | 11 | Zabbix hace ping a todas las VLAN y consulta agentes de GESTIÓN; no puede abrir SSH hacia otras VLAN |

```bash
./lab/lab.sh probar              # todos los perfiles de las VMs encendidas
./lab/lab.sh probar users mgmt   # solo algunos
sudo /mnt/proyecto/pruebas/probar.sh intruso     # dentro de una VM
```

Salida de un caso: `U04 PASS BLOQUEADO BLOQUEADO ping 192.168.10.50 - USUARIOS -> ADMIN denegado` (identificador, veredicto, esperado, obtenido, prueba).

- `BLOQUEADO`: no hubo respuesta; la ACL descarta en silencio.
- `RECHAZADO`: hubo respuesta negativa; se llegó al equipo pero el puerto está cerrado.

Los resultados quedan en `evidencias/pruebas/` (un archivo por perfil y un resumen por ejecución).

## 3. Demostraciones en vivo

### 3.1 DHCP restringido: equipo registrado frente a intruso

| Paso | Dónde | Orden | Se ve |
|---|---|---|---|
| 1 | R1 | `sudo xelaju-dhcp listar` | 3 equipos; el intruso no está |
| 2 | PC-USER01 | `sudo ifdown lan0 && sudo ifup lan0` | DHCPDISCOVER → DHCPOFFER → DHCPREQUEST → DHCPACK, `bound to 192.168.20.10` |
| 3 | R1 | `sudo xelaju-dhcp log` | las cuatro líneas con `aa:bb:cc:dd:ee:01` |
| 4 | PC-INTRUSO | `sudo dhclient -v lan0` | DHCPDISCOVER repetido y `No DHCPOFFERS received` |
| 5 | R1 | `sudo xelaju-dhcp log` | `DHCPDISCOVER from aa:bb:cc:dd:ee:99 ... no free leases` |
| 6 | PC-INTRUSO | `sudo ip addr add 192.168.20.99/24 dev lan0; sudo ip route add default via 192.168.20.1; ping -c 3 192.168.20.1` | sin respuesta |
| 7 | R1 | `sudo tail /var/log/xelaju/acl-lan.log` | `ACL-DENY USERS-NOREG->R1 ... MAC=...ee:99... SRC=192.168.20.99` |
| 8 | R1 | `sudo xelaju-dhcp alta PC-INTRUSO aa:bb:cc:dd:ee:99` | `Alta: PC-INTRUSO ... -> 192.168.20.13` |
| 9 | PC-INTRUSO | `sudo ip addr flush dev lan0; sudo dhclient -v lan0` | `bound to 192.168.20.13`; ahora navega |
| 10 | R1 | `sudo xelaju-dhcp baja PC-INTRUSO` | baja y corte inmediato de sus conexiones |
| 11 | PC-INTRUSO | `ping -c 3 192.168.20.1` | sin respuesta otra vez |

### 3.2 ACL con contadores

```bash
sudo nft list chain inet xelaju desde_users     # en R1
```

Tras `./lab/lab.sh probar users`, la regla `USERS->ADMIN` muestra `counter packets N` con N mayor que cero: la denegación la hizo esa regla y no una casualidad. `sudo r1-estado` resume permitidos y bloqueados por cadena.

### 3.3 INPUT no es FORWARD

| Prueba desde PC-USER01 | Cadena de R1 que decide | Resultado |
|---|---|---|
| `ping 192.168.20.1` (su puerta de enlace) | `entrada` | responde |
| `ping 192.168.10.1` (otra IP del propio R1) | `entrada` | bloqueado |
| `ping 192.168.10.50` (PC-ADMIN01, atraviesa R1) | `reenvio` → `desde_users` | bloqueado |
| `ssh 192.168.20.1` | `entrada` | bloqueado |

### 3.4 Cambio de modo

```bash
sudo r1-modo estado      # individual, NAT en R1: si
sudo r1-modo grupal      # up-squid con 192.168.84.2/30, ruta por defecto por Squid, NAT en R1: no
sudo nft list ruleset | grep -c 'type nat'      # 0
sudo r1-modo individual
```

Sin el equipo de Squid conectado, en modo grupal la LAN se queda sin Internet (es lo esperado): volver a `individual` para seguir trabajando solo.

### 3.5 Frontera con el firewall (sin los compañeros)

```bash
./pruebas/simular-lan.sh -v grupal | less       # en el host
```

Al final, las comprobaciones "Sin E5…" vacían las reglas del doble del firewall y repiten pruebas contra R1: la DMZ sigue sin poder entrar a la LAN y la web de Zabbix sigue cerrada, pero un cliente VPN-USERS sí llegaría a la VLAN ADMIN. Es la forma de mostrar qué controla R1 y qué controla E5 (ADR-0002).

### 3.6 Persistencia

Reiniciar R1 y un switch (`sudo reboot`, o `./lab/lab.sh detener <vm>` e `iniciar <vm>`) y repetir `sudo r1-estado` y `switch-mostrar vlan`: todo vuelve igual sin ejecutar nada.

## 4. Capa 2

| Qué | Orden | Se ve |
|---|---|---|
| VLAN y puertos de acceso | `switch-mostrar vlan` (en cada switch) | cada VLAN con sus puertos; sin VLAN 1 |
| Troncales | `switch-mostrar trunk` | `p0 ... 10,20,30,40` y `p1 ... 10,20,40` en SW-CORE01 |
| Tabla MAC | `switch-mostrar mac` | cada MAC en su VLAN y su puerto |
| Etiquetas 802.1Q | `sudo tcpdump -e -n -c 20 -i p0` en SW-CORE01 | `ethertype 802.1Q (0x8100) ... vlan 10` (y 20, 30, 40) |
| Puerto de acceso sin etiqueta | `sudo tcpdump -e -n -c 10 -i p2` en SW-CORE01 | `ethertype IPv4`, sin `vlan` |
| Poda de la VLAN 30 | `sudo tcpdump -e -n -i p1 vlan 30` en SW-CORE01 | nada, aunque haya tráfico de servidores |
| SPAN | `switch-span estado` | `origen p0 (ambos sentidos) -> destino p5` |

En una troncal la etiqueta va dentro de la trama: para filtrar hay que anteponer `vlan` (por ejemplo `tcpdump -i p0 vlan and icmp`). El filtro `icmp` solo no muestra nada.

## 5. Capturas para Wireshark

`lab.sh capturar` graba, desde el host, lo que pasa por un cable virtual, con las etiquetas 802.1Q. Los archivos quedan en `evidencias/pcap/`.

| Evidencia | Captura | Mientras tanto | Filtro en Wireshark |
|---|---|---|---|
| Troncal etiquetada | `./lab/lab.sh capturar sw-core01 p0 40` | `./lab/lab.sh probar admin` | `vlan.id == 10`, `vlan.id == 30` |
| DORA de un equipo registrado | `./lab/lab.sh capturar sw-acc01 p2 30` | en PC-USER01: `sudo ifdown lan0 && sudo ifup lan0` | `dhcp` |
| DISCOVER sin respuesta | `./lab/lab.sh capturar sw-acc01 p4 30` | en PC-INTRUSO: `sudo dhclient -v lan0` | `dhcp` |
| ICMP bloqueado (USUARIOS → ADMIN) | `./lab/lab.sh capturar sw-acc01 p2 20` | en PC-USER01: `ping -c 5 192.168.10.50` | `icmp` (solo peticiones) |
| El bloqueo ocurre en R1 | `./lab/lab.sh capturar sw-acc01 p1 20` | el mismo ping | `icmp` (no llega nada a PC-ADMIN01) |
| Puerto espejo | `./lab/lab.sh capturar sw-core01 p5 30` | cualquier tráfico entre VLAN | copia de la troncal, con etiquetas |
| Salida con NAT (individual) | `./lab/lab.sh capturar r1-lan tmp-nat 20` | en PC-USER01: `curl -sI http://deb.debian.org` | origen 10.0.2.15 |
| Salida sin NAT (grupal) | `./lab/lab.sh capturar r1-lan up-squid 20` | el mismo `curl` | origen 192.168.20.10 |

## 6. Evidencias de consola

| Evidencia | Equipo | Orden |
|---|---|---|
| Resumen del router | R1 | `sudo r1-estado` |
| Tabla de rutas | R1 | `ip route` |
| Reglas con contadores | R1 | `sudo nft list ruleset` |
| Registro de las ACL | R1 | `sudo tail -30 /var/log/xelaju/acl-lan.log` |
| Registro del DHCP | R1 | `sudo tail -30 /var/log/xelaju/dhcpd.log` |
| Registro de altas y bajas | R1 | `sudo xelaju-dhcp log` |
| Estado del DHCP | R1 | `sudo xelaju-dhcp verificar` |
| Estado del switch | SW-CORE01, SW-ACC01 | `switch-mostrar todo`, `switch-mostrar config` |
| Dirección de cada equipo | todos | `ip -br addr` |
| Zabbix | PC-ADMIN01 | capturas de los dos dashboards y de *Monitoring → Hosts* |

La lista de archivos a entregar, con su nombre, está en `evidencias/README.md`.
