# 01 — Diseño de red de la LAN (Estudiante 1)

Este documento describe **qué** se construye y **por qué**. Cómo se levanta está en `02-runbook-individual.md`; cada script se explica en `06-scripts.md`.

Hay dos fuentes de verdad, una dentro de la otra:

- **`core/ADDRESSING.yaml`**, el plan de direccionamiento del grupo (en esta entrega, [`tablas/direccionamiento.csv`](../../tablas/direccionamiento.csv) y [`tablas/rutas.csv`](../../tablas/rutas.csv)), fija lo que se comparte: las cuatro VLAN y sus puertas de enlace, el enlace con Squid, la IP de Zabbix y las redes de los compañeros. Aquí no se decide ninguno de esos valores.
- **`lab/topologia.conf`** fija lo que es solo del laboratorio de la LAN: VM, MAC, cables y direcciones de cada equipo.

`pruebas/consistencia.py` comprueba que este documento nombra las mismas direcciones IP y MAC que la topología y, en el repositorio de trabajo del grupo, que las dos fuentes coinciden.

## 1. Topología lógica

```
        modo individual: NAT de QEMU 10.0.2.2      modo grupal: Squid (E2) 192.168.84.1
                           │                                   │
        tmp-nat 10.0.2.15 ─┘                                   └─ up-squid 192.168.84.2/30
                           └────────────── R1-LAN ─────────────┘
                                trunk0  (troncal 802.1Q: VLAN 10, 20, 30, 40)
                                   │  cable c01
                                  p0
                              SW-CORE01 ── gestión 192.168.40.2
            p1 troncal 10,20,40 │   p2 VLAN30   p3 VLAN30   p4 VLAN40   p5 SPAN(p0)
                     cable c02  │      │           │           │
                                │  ZBX-SRV01   SRV-INTRA01  PC-MGMT01
                               p0  .30.10        .30.20       .40.10
                              SW-ACC01 ── gestión 192.168.40.3
                 p1 VLAN10    p2 VLAN20    p3 VLAN20    p4 VLAN20
                    │            │            │            │
                PC-ADMIN01   PC-USER01    PC-USER02    PC-INTRUSO
                  .10.50      .20.10       .20.11     (sin registro)
```

Modelo: **router-on-a-stick**. Un solo enlace troncal entre el switch de núcleo y el router transporta todas las VLAN; el router tiene una subinterfaz por VLAN y enruta entre ellas. Todo el tráfico entre VLAN pasa por R1, que es donde se aplican las ACL.

### Dónde queda la LAN dentro del grupo

```
 Internet ── E3 Multi-WAN ──81.0/30── E5 Firewall+IDS ──82.0/30── E2 Squid ──84.0/30── R1-LAN ── VLAN 10/20/30/40
             (único NAT)                    │
                                         83.0/30
                                            │
                                     E4 VPN (WireGuard) y DMZ (WEB01)
```

R1 tiene **un solo enlace** con el resto del grupo: `up-squid`, hacia E2. No hay enlace directo entre R1 y VPN/DMZ (ADR-0001): los clientes VPN llegan a la LAN por E4 → E5 → E2 → R1, y la LAN llega a la DMZ por el camino inverso. Por eso a R1 le basta una ruta por defecto.

## 2. VLAN

| VLAN | Nombre | Red | Uso | Método de direccionamiento |
|---|---|---|---|---|
| 10 | ADMIN | 192.168.10.0/24 | Equipos de administradores | Manual |
| 20 | USUARIOS | 192.168.20.0/24 | Equipos de usuarios | DHCP restringido (reserva por MAC) |
| 30 | SERVIDORES | 192.168.30.0/24 | Zabbix e Intranet | Manual |
| 40 | GESTIÓN | 192.168.40.0/24 | Administración de switches | Manual |

No existe la VLAN 1: los switches se crean con `vlan_default_pvid 0`, así que un puerto sin configurar no pertenece a ninguna VLAN.

## 3. Direccionamiento y subnetting

### Redes

| Red | Prefijo | Máscara | Puerta de enlace | Uso |
|---|---|---|---|---|
| 192.168.10.0 | /24 | 255.255.255.0 | 192.168.10.1 | VLAN 10 ADMIN |
| 192.168.20.0 | /24 | 255.255.255.0 | 192.168.20.1 | VLAN 20 USUARIOS |
| 192.168.30.0 | /24 | 255.255.255.0 | 192.168.30.1 | VLAN 30 SERVIDORES |
| 192.168.40.0 | /24 | 255.255.255.0 | 192.168.40.1 | VLAN 40 GESTIÓN |
| 192.168.84.0 | /30 | 255.255.255.252 | 192.168.84.1 | Enlace R1 ↔ Squid, `link_e1_e2` de `core/` (solo modo grupal) |
| 10.0.2.0 | /24 | 255.255.255.0 | 10.0.2.2 | Salida temporal por el NAT de QEMU (solo modo individual) |

Redes de los compañeros que R1 nombra en sus reglas (valores de `core/ADDRESSING.yaml`): VPN-ADMIN 10.200.10.0/24, VPN-USERS 10.200.20.0/24 y los enlaces de tránsito 192.168.81.0/30 (E3–E5), 192.168.82.0/30 (E5–E2) y 192.168.83.0/30 (E5–E4).

### Justificación

- **/24 por VLAN.** 254 direcciones útiles: sobra para el laboratorio y deja crecer. El tercer octeto coincide con el número de VLAN (VLAN 20 → 192.168.**20**.0), lo que hace la red legible y evita errores.
- **/30 en los enlaces punto a punto.** Un /30 tiene 4 direcciones: red, dos útiles y difusión. Exactamente las dos que necesita un enlace entre dos routers; no se desperdicia nada. Convención del grupo (ADR-0002): la `.1` es el lado más cercano a Internet y la `.2` el más cercano a la LAN; por eso R1 es 192.168.84.2.
- **Sin resumir las VLAN.** Las cuatro redes cabrían en un solo prefijo más corto (un /18), y una única ruta de vuelta sería más cómoda para los compañeros. El grupo decidió no hacerlo (ADR-0002): las redes de los ISP también suelen ser 192.168.x.x y un resumen podría taparlas en el Multi-WAN. Cada equipo lleva **una ruta por VLAN** y las reglas de R1 nombran las cuatro redes una por una (`REDES_LAN`).

### Equipos (tabla de direccionamiento)

Columnas del enunciado (Dispositivo, Interfaz, IP, Máscara, Gateway, Red), más la MAC y la conexión física.

| Dispositivo | Interfaz | IP | Máscara | Gateway | Red | MAC | Conectado a |
|---|---|---|---|---|---|---|---|
| R1-LAN | trunk0 | — (troncal, sin IP) | — | — | — | 52:54:00:01:00:00 | SW-CORE01 p0 |
| R1-LAN | trunk0.10 | 192.168.10.1 | 255.255.255.0 | — | 192.168.10.0/24 | (la de trunk0) | VLAN 10 (puerta de enlace) |
| R1-LAN | trunk0.20 | 192.168.20.1 | 255.255.255.0 | — | 192.168.20.0/24 | (la de trunk0) | VLAN 20 (puerta de enlace) |
| R1-LAN | trunk0.30 | 192.168.30.1 | 255.255.255.0 | — | 192.168.30.0/24 | (la de trunk0) | VLAN 30 (puerta de enlace) |
| R1-LAN | trunk0.40 | 192.168.40.1 | 255.255.255.0 | — | 192.168.40.0/24 | (la de trunk0) | VLAN 40 (puerta de enlace) |
| R1-LAN | tmp-nat | 10.0.2.15 | 255.255.255.0 | 10.0.2.2 | 10.0.2.0/24 | 52:54:00:01:00:03 | NAT de QEMU (solo modo individual) |
| R1-LAN | up-squid | 192.168.84.2 | 255.255.255.252 | 192.168.84.1 | 192.168.84.0/30 | 52:54:00:01:00:01 | Squid, E2 (solo modo grupal) |
| SW-CORE01 | br0.40 | 192.168.40.2 | 255.255.255.0 | 192.168.40.1 | 192.168.40.0/24 | 52:54:00:02:00:00 | gestión del switch (VLAN 40) |
| SW-ACC01 | br0.40 | 192.168.40.3 | 255.255.255.0 | 192.168.40.1 | 192.168.40.0/24 | 52:54:00:03:00:00 | gestión del switch (VLAN 40) |
| ZBX-SRV01 | lan0 | 192.168.30.10 | 255.255.255.0 | 192.168.30.1 | 192.168.30.0/24 | 52:54:00:30:00:10 | SW-CORE01 p2 |
| SRV-INTRA01 | lan0 | 192.168.30.20 | 255.255.255.0 | 192.168.30.1 | 192.168.30.0/24 | 52:54:00:30:00:20 | SW-CORE01 p3 |
| PC-MGMT01 | lan0 | 192.168.40.10 | 255.255.255.0 | 192.168.40.1 | 192.168.40.0/24 | 52:54:00:40:00:10 | SW-CORE01 p4 |
| PC-ADMIN01 | lan0 | 192.168.10.50 | 255.255.255.0 | 192.168.10.1 | 192.168.10.0/24 | 52:54:00:10:00:50 | SW-ACC01 p1 |
| PC-USER01 | lan0 | 192.168.20.10 (DHCP, reserva) | 255.255.255.0 | 192.168.20.1 | 192.168.20.0/24 | aa:bb:cc:dd:ee:01 | SW-ACC01 p2 |
| PC-USER02 | lan0 | 192.168.20.11 (DHCP, reserva) | 255.255.255.0 | 192.168.20.1 | 192.168.20.0/24 | aa:bb:cc:dd:ee:02 | SW-ACC01 p3 |
| PC-USER03 | — | 192.168.20.12 (reserva) | 255.255.255.0 | 192.168.20.1 | 192.168.20.0/24 | aa:bb:cc:dd:ee:03 | equipo de pruebas del Est. 3 |
| PC-INTRUSO | lan0 | ninguna | — | — | — | aa:bb:cc:dd:ee:99 | SW-ACC01 p4 |

Convención de MAC del laboratorio: `52:54:00:<equipo>:00:<puerto u octeto>`. Los PC de usuarios usan las MAC del registro. El bridge de cada switch toma la MAC de su puerto p0.

## 4. Switches

### SW-CORE01 (núcleo) — MAC de puertos 52:54:00:02:00:00 a 52:54:00:02:00:05

| Puerto | Modo | VLAN | Conectado a | MAC del puerto |
|---|---|---|---|---|
| p0 | Troncal 802.1Q | 10, 20, 30, 40 | R1-LAN trunk0 | 52:54:00:02:00:00 |
| p1 | Troncal 802.1Q | 10, 20, 40 | SW-ACC01 p0 | 52:54:00:02:00:01 |
| p2 | Acceso | 30 | ZBX-SRV01 | 52:54:00:02:00:02 |
| p3 | Acceso | 30 | SRV-INTRA01 | 52:54:00:02:00:03 |
| p4 | Acceso | 40 | PC-MGMT01 | 52:54:00:02:00:04 |
| p5 | SPAN | espejo de p0 | (captura) | 52:54:00:02:00:05 |

### SW-ACC01 (acceso) — MAC de puertos 52:54:00:03:00:00 a 52:54:00:03:00:04

| Puerto | Modo | VLAN | Conectado a | MAC del puerto |
|---|---|---|---|---|
| p0 | Troncal 802.1Q | 10, 20, 40 | SW-CORE01 p1 | 52:54:00:03:00:00 |
| p1 | Acceso | 10 | PC-ADMIN01 | 52:54:00:03:00:01 |
| p2 | Acceso | 20 | PC-USER01 | 52:54:00:03:00:02 |
| p3 | Acceso | 20 | PC-USER02 | 52:54:00:03:00:03 |
| p4 | Acceso | 20 | PC-INTRUSO | 52:54:00:03:00:04 |

Decisiones:

- **Poda de la VLAN 30** en la troncal entre switches: en SW-ACC01 no hay servidores, así que esa VLAN no viaja hasta allí. Menos difusión y menos superficie.
- **Sin VLAN nativa**: en las troncales todas las tramas van etiquetadas. Una trama sin etiqueta que llegue a una troncal se descarta.
- **Sin Spanning Tree**: la topología es un árbol, no tiene lazos.
- **Gestión en la VLAN 40**: cada switch tiene una IP solo en esa VLAN (equivale a `interface vlan 40`).
- **SPAN en p5**: copia todo lo que entra y sale por la troncal hacia R1, con sus etiquetas 802.1Q.

## 5. Enrutamiento

Formato del enunciado: Dispositivo, Red destino, Máscara, Next Hop, Interfaz.

### Tabla de rutas de los equipos de la LAN

| Dispositivo | Red destino | Máscara | Next Hop | Interfaz | Tipo y modo |
|---|---|---|---|---|---|
| R1-LAN | 192.168.10.0 | 255.255.255.0 | conectada | trunk0.10 | Conectada · ambos modos |
| R1-LAN | 192.168.20.0 | 255.255.255.0 | conectada | trunk0.20 | Conectada · ambos modos |
| R1-LAN | 192.168.30.0 | 255.255.255.0 | conectada | trunk0.30 | Conectada · ambos modos |
| R1-LAN | 192.168.40.0 | 255.255.255.0 | conectada | trunk0.40 | Conectada · ambos modos |
| R1-LAN | 10.0.2.0 | 255.255.255.0 | conectada | tmp-nat | Conectada · individual |
| R1-LAN | 0.0.0.0 | 0.0.0.0 | 10.0.2.2 | tmp-nat | Estática por defecto · individual |
| R1-LAN | 192.168.84.0 | 255.255.255.252 | conectada | up-squid | Conectada · grupal |
| R1-LAN | 0.0.0.0 | 0.0.0.0 | 192.168.84.1 | up-squid | Estática por defecto · grupal |
| SW-CORE01 | 0.0.0.0 | 0.0.0.0 | 192.168.40.1 | br0.40 | Estática por defecto (gestión) |
| SW-ACC01 | 0.0.0.0 | 0.0.0.0 | 192.168.40.1 | br0.40 | Estática por defecto (gestión) |
| ZBX-SRV01 | 0.0.0.0 | 0.0.0.0 | 192.168.30.1 | lan0 | Estática por defecto |
| SRV-INTRA01 | 0.0.0.0 | 0.0.0.0 | 192.168.30.1 | lan0 | Estática por defecto |

La ruta por defecto del modo grupal cubre Internet, las redes VPN (10.200.10.0/24 y 10.200.20.0/24) y la DMZ (172.16.10.0/24): todas quedan detrás de E2, así que R1 no necesita rutas estáticas propias para ellas.

En modo individual R1 hace NAT (masquerade) de las cuatro VLAN al salir por `tmp-nat`. En modo grupal **R1 no hace NAT**: el único NAT del grupo lo hace el Multi-WAN (ADR-0002).

### Rutas que necesitan los demás equipos

Las fija `routing_plan` en `core/ADDRESSING.yaml`; aquí solo se resume lo que toca a la LAN. Como R1 no hace NAT, cada equipo del camino necesita saber volver a las VLAN, **una ruta por VLAN** (192.168.10.0, 192.168.20.0, 192.168.30.0 y 192.168.40.0, máscara 255.255.255.0):

| Dispositivo | Red destino | Next Hop | Para qué |
|---|---|---|---|
| Squid (E2) | las 4 VLAN | 192.168.84.2 (R1) | Volver a las VLAN; además debe reenviar IP entre sus dos enlaces |
| Firewall (E5) | las 4 VLAN | 192.168.82.2 (E2) | Volver a las VLAN |
| Multi-WAN (E3) | las 4 VLAN | 192.168.81.2 (E5) | Volver a las VLAN |
| Hosts de cada VLAN | 0.0.0.0 | la .1 de su VLAN | Puerta de enlace (ver tabla de direccionamiento) |

## 6. Matriz de seguridad (ACL de R1-LAN)

Política por omisión: **denegar**. Con estado: las respuestas de una conexión permitida pasan solas. Cada denegación se registra con el prefijo `ACL-DENY ORIGEN->DESTINO`.

### Tráfico que atraviesa R1 (cadena `reenvio`)

| Origen | Destino | Servicio | Acción |
|---|---|---|---|
| ADMIN | USUARIOS, SERVIDORES (incluida la web de Zabbix), GESTIÓN | cualquiera | Permitir y registrar (`ACL-ALLOW`) |
| ADMIN | Internet, DMZ y demás redes detrás de E2 | cualquiera | Permitir |
| USUARIOS | ADMIN, GESTIÓN | cualquiera | **Denegar** + registro |
| USUARIOS | SRV-INTRA01 192.168.30.20 | TCP 80, 443 | Permitir |
| USUARIOS | resto de SERVIDORES (ping, SSH, web de Zabbix) | — | **Denegar** + registro |
| USUARIOS | Internet y DMZ (salida por E2) | cualquiera | Permitir, **solo si el par MAC·IP está registrado** |
| USUARIOS no registrado | todo | — | **Denegar** + registro (`USERS-NOREG`) |
| SERVIDORES (solo ZBX 192.168.30.10) | todas las VLAN | ICMP eco; a GESTIÓN además TCP 10050 y UDP 161 | Permitir (monitoreo) |
| SERVIDORES | ADMIN, USUARIOS, GESTIÓN (lo demás) | — | **Denegar** + registro |
| SERVIDORES | Internet | cualquiera | Permitir |
| GESTIÓN | SERVIDORES | TCP 22; TCP 10051 a ZBX; ICMP eco | Permitir |
| GESTIÓN | web de Zabbix (TCP 80/443) | — | **Denegar** + registro |
| GESTIÓN | ADMIN, USUARIOS | — | **Denegar** + registro |
| GESTIÓN | Internet | TCP 53, 80, 443; UDP 53, 123 | Permitir (solo actualizaciones) |
| Perímetro (enlace de salida) | cualquier VLAN, con una IP de origen de la LAN | — | **Denegar** + registro (`ACL-SPOOF PERIMETRO`) |
| Perímetro | web de Zabbix (TCP 80/443) | — | **Denegar** + registro: es solo de la VLAN ADMIN, tampoco por VPN |
| VPN-ADMIN y VPN-USERS (grupal) | todas las VLAN | lo que E5 ya autorizó | Permitir y registrar (`ACL-ALLOW VPN->LAN`) |
| Enlaces de tránsito 192.168.81–84.0/30 (grupal) | ZBX | TCP 10051 | Permitir (agentes de Zabbix de los compañeros) |
| Perímetro (Internet, DMZ, cualquier otro) | LAN | conexiones nuevas | **Denegar** + registro (`PERIMETRO->LAN`) |

Además, cada cadena empieza con **anti-suplantación**: si la IP de origen no pertenece a la red de la interfaz por la que entra el paquete, se registra (`ACL-SPOOF`) y se descarta.

### Frontera entre R1 (E1) y el firewall (E5)

El enunciado reparte así el control de acceso: **entre VLAN, R1; perímetro (Internet, VPN, DMZ), el firewall del Estudiante 5**. El firewall no repite las ACL internas y R1 no repite la política perimetral.

- La política VPN (VPN-ADMIN a todas las VLAN; VPN-USERS solo a USUARIOS y a los servicios permitidos de SERVIDORES) la aplica **E5** en su segunda pasada, cuando el tráfico ya salió descifrado de WireGuard (ADR-0001). R1 recibe ese tráfico por `up-squid` y **lo deja pasar sin volver a filtrarlo** (ADR-0002, propuesta para E1 n.º 2).
- R1 sí conserva lo que es suyo: anti-suplantación, la web de Zabbix solo para la VLAN ADMIN y "lo que no es VPN ni monitoreo no entra". La DMZ, por ejemplo, no puede iniciar conexiones hacia la LAN aunque E5 fallara.
- Consecuencia que hay que saber explicar: si E5 dejara pasar todo, un cliente VPN-USERS llegaría a la VLAN ADMIN. `pruebas/simular-lan.sh grupal` lo demuestra a propósito (comprobaciones "Sin E5…").
- No hay reglas sobre el portal de administración de Squid (puerto 8080 de E2). Lo restringe el propio E2: su portal solo responde a la VLAN ADMIN y devuelve `403` al resto, comprobado desde las VLAN 10, 20 y 30.

### Tráfico dirigido al propio R1 (cadena `entrada`)

| Origen | Servicio en R1 | Acción |
|---|---|---|
| VLAN 20 | DHCP (UDP 67) | Permitir (es la única VLAN donde escucha el servidor) |
| VLAN 20, equipo no registrado | cualquiera | **Denegar** + registro |
| ADMIN | ping a cualquier IP de R1, SSH | Permitir |
| USUARIOS registrados | ping a 192.168.20.1 | Permitir. SSH: **denegar** |
| SERVIDORES | ping a 192.168.30.1 | Permitir |
| ZBX | ping a cualquier IP de R1, TCP 10050 | Permitir (monitoreo) |
| GESTIÓN | ping a 192.168.40.1, SSH | Permitir |
| Host del laboratorio (individual) | SSH por `tmp-nat` desde 10.0.2.2 | Permitir (acceso fuera de banda) |
| Equipos del grupo, desde los enlaces de tránsito 192.168.81–84.0/30 (grupal) | ping a 192.168.84.2 | Permitir (prueba de cableado y de rutas) |
| Cualquier otro | cualquiera | **Denegar** + registro |

### Capas de protección de la web de Zabbix

1. ACL de R1: solo ADMIN llega a 192.168.30.10:80.
2. nftables del propio ZBX-SRV01: TCP 80 solo desde 192.168.10.0/24.
3. Apache: `Require ip 192.168.10.0/24 127.0.0.1` (responde 403 a cualquier otro).

## 7. DHCP restringido (VLAN 20)

Flujo del enunciado y cómo se cumple:

| Paso | Qué ocurre | Dónde |
|---|---|---|
| 1. Registro | El equipo se anota en `/etc/xelaju/usuarios.csv` (`Equipo,Direccion_MAC,IP_reservada`) con `xelaju-dhcp alta` | R1-LAN |
| 2. Solicitud | El cliente envía DHCPDISCOVER por difusión en la VLAN 20 | cliente |
| 3. Validación | dhcpd busca una declaración `host` con esa MAC | `reservas-vlan20.conf` |
| 4. Asignación | Si existe: DHCPOFFER/DHCPACK con IP fija, máscara, puerta de enlace y DNS | `dhcpd.conf` |
| 5. Rechazo | Si no existe: no hay oferta; en el registro queda `no free leases` | `/var/log/xelaju/dhcpd.log` |
| 6. IP fija | Cada renovación entrega la misma dirección (`fixed-address`) | — |

Tres mecanismos lo garantizan:

- El servidor **solo escucha en `trunk0.20`** (`INTERFACESv4`).
- La subred **no tiene `range`**: no hay direcciones dinámicas que entregar.
- **Binding MAC·IP en las ACL**: del mismo CSV se genera un conjunto de nftables con los pares autorizados. Un equipo que se ponga una IP a mano, o que use la IP de otro, no pasa de R1.

### 7.1 Qué está escrito a mano y qué hace un script

El servicio es `isc-dhcp-server`, el DHCP nativo de Debian, con su configuración en archivos de texto. Ningún script lo sustituye: lo único automatizado es escribir los bloques `host` a partir del CSV e instalar los archivos.

| Archivo en R1-LAN | Cómo se obtiene | Contenido |
|---|---|---|
| `/etc/dhcp/dhcpd.conf` | Escrito a mano | La `subnet` de la VLAN 20 sin `range`, puerta de enlace, DNS, tiempos de préstamo y el `include` de las reservas |
| `/etc/default/isc-dhcp-server` | Escrito a mano | `INTERFACESv4="trunk0.20"` |
| `/etc/xelaju/usuarios.csv` | Escrito a mano (o con `xelaju-dhcp alta` / `baja`) | La relación MAC/IP que pide el enunciado |
| `/etc/dhcp/reservas-vlan20.conf` | Generado por `xelaju-dhcp` | Un bloque `host` por fila del CSV |
| `/etc/nftables.d/10-registrados.nft` | Generado por `xelaju-dhcp` | El conjunto MAC·IP que usan las ACL |

La instalación la hace `nodos/r1-lan/aplicar.sh`: instala el paquete, copia los archivos, ejecuta `xelaju-dhcp aplicar` y habilita el servicio. A mano equivale a `apt install isc-dhcp-server`, copiar los tres archivos escritos a mano y `systemctl enable --now isc-dhcp-server`.

El enunciado pide el servicio DHCP nativo con reservas por MAC y permite los scripts de automatización si se entregan y se documentan (`xelaju-dhcp` está descrito en `06-scripts.md`).

### 7.2 Registrar un equipo sin el script

`dhcpd` no lee el CSV: lee los bloques `host`. Registrar a mano un equipo nuevo (por ejemplo PC-USER04) son cuatro pasos en R1-LAN:

1. Añadir la fila al CSV, que sigue siendo la lista de equipos autorizados:

   ```
   PC-USER04,aa:bb:cc:dd:ee:04,192.168.20.13
   ```

2. Añadir la reserva en `/etc/dhcp/reservas-vlan20.conf`:

   ```
   host PC-USER04 {
       hardware ethernet aa:bb:cc:dd:ee:04;
       fixed-address 192.168.20.13;
       option host-name "PC-USER04";
   }
   ```

3. Comprobar la configuración y reiniciar el servicio:

   ```bash
   sudo dhcpd -t -q -cf /etc/dhcp/dhcpd.conf
   sudo systemctl restart isc-dhcp-server
   ```

4. Añadir el par MAC·IP a las ACL. Sin este paso el equipo recibe su dirección, pero R1 descarta su tráfico (`ACL-DENY USERS-NOREG`):

   ```bash
   sudo nft add element inet xelaju registrados { aa:bb:cc:dd:ee:04 . 192.168.20.13 }
   ```

   Para que sobreviva a un reinicio, el mismo par se añade a `elements` en `/etc/nftables.d/10-registrados.nft`.

`xelaju-dhcp alta PC-USER04 aa:bb:cc:dd:ee:04` hace esos cuatro pasos juntos, valida antes los datos y, si `dhcpd -t` o `nft -c` rechazan el resultado, restaura los archivos anteriores. La siguiente ejecución de `xelaju-dhcp aplicar` vuelve a generar los dos archivos derivados desde el CSV: una reserva escrita a mano que no esté también en el CSV (paso 1) se pierde.

## 8. Trazabilidad: requisito → archivo → evidencia

| Requisito del Estudiante 1 | Archivo(s) | Evidencia |
|---|---|---|
| VLAN y configuración de switches | `nodos/_comun/switch/*`, `nodos/sw-*/switch.conf`, `puertos.conf` | `switch-mostrar vlan` en ambos switches |
| Troncales 802.1Q | `puertos.conf` (modo `trunk`) | `switch-mostrar trunk`; `.pcap` de la troncal con etiquetas |
| Puertos de acceso | `puertos.conf` (modo `access`) | `switch-mostrar vlan` y `puertos` |
| IPv4 manual y subnetting | `nodos/*/interfaces`, este documento | `ip -br addr` en cada equipo |
| Router inter-VLAN | `nodos/r1-lan/rootfs/etc/network/interfaces`, `sysctl.d/90-xelaju-router.conf` | `r1-estado` |
| Rutas estáticas | `interfaces`, `modos/individual`, `modos/grupal` | `ip route` en R1 |
| Puerta de enlace de cada VLAN | subinterfaces `trunk0.N` | ping a la .1 desde cada VLAN |
| ACL entre redes internas | `nftables.conf`, `nftables.d/*.nft` | `pruebas/probar.sh`, contadores de `nft list ruleset`, `acl-lan.log` |
| DHCP restringido en la VLAN 20 | `dhcpd.conf`, `default/isc-dhcp-server`, `usuarios.csv`, `xelaju-dhcp` | `dhcpd.log`, `.pcap` con DORA y con DISCOVER sin respuesta |
| Archivo externo de usuarios | `etc/xelaju/usuarios.csv` | `xelaju-dhcp listar` |
| Zabbix en la VLAN 30, solo desde ADMIN | `nodos/zbx-srv01/*` | web desde PC-ADMIN01 (200) y desde otros (bloqueado) |
| Métricas del Multi-WAN en Zabbix | `nodos/zbx-srv01/monitoreo.py` (equipo `Router-MultiWAN-E3`, claves `multiwan.isp*`) | dashboard "Multi-WAN - Estudiante 3" |
| Scripts documentados | `docs/06-scripts.md` | — |
| Diagrama | `docs/diagramas/estudiante1-lan.drawio` | exportado a PNG/PDF |
