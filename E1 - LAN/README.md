# Estudiante 1 — Segmentación LAN, DHCP y Monitoreo Zabbix

**Responsable:** Estudiante 1<br>
**Curso:** Redes de Computadoras 2 — CUNOC / USAC<br>
**Sistema:** Debian GNU/Linux 13 "trixie" (Modo Consola / Texto; solo los PC de prueba tienen escritorio)<br>
**Rol en la infraestructura:** Enrutamiento inter-VLAN interno, control de acceso local, servidor DHCP restringido para usuarios y plataforma centralizada de monitoreo de red (Zabbix).

---

## 1. Descripción y Responsabilidad del Componente

El componente **E1** es la red local (LAN) de XelajuNetwork. Comprende:

- Segmentación en 4 VLAN bajo IEEE 802.1Q, con dos switches (núcleo y acceso), troncales y puertos de acceso.
- Router inter-VLAN **R1-LAN** (*router-on-a-stick*): puerta de enlace de cada VLAN, rutas estáticas y listas de control de acceso (ACL) entre las redes internas.
- DHCP restringido en la VLAN 20: solo reciben dirección los equipos registrados por MAC en un archivo CSV, con el servicio tradicional de Debian (`isc-dhcp-server`; no se usa Kea).
- Servidor Zabbix 7.0 LTS en la VLAN 30 (`192.168.30.10`), con la web accesible solo desde la VLAN ADMIN, que recibe además las métricas del Multi-WAN de E3.

Todo corre en un laboratorio de 10 máquinas virtuales QEMU sobre un host Debian, creado y configurado con scripts.

```text
 Internet ── E3 ── E5 ──┬── E2 (Squid) ──84.0/30── R1-LAN ── troncal 802.1Q ── SW-CORE01 ── troncal ── SW-ACC01
                        └── E4 (VPN/DMZ)                                         │  VLAN 30, 40           │  VLAN 10, 20
                                                                        ZBX-SRV01, SRV-INTRA01     PC-ADMIN01, PC-USER01/02
                                                                        PC-MGMT01                  PC-INTRUSO
```

| VLAN | Red | Puerta de enlace | Equipos del laboratorio | Direccionamiento |
|---|---|---|---|---|
| 10 ADMIN | `192.168.10.0/24` | `192.168.10.1` | PC-ADMIN01 | Manual |
| 20 USUARIOS | `192.168.20.0/24` | `192.168.20.1` | PC-USER01, PC-USER02 (y PC-INTRUSO, sin registrar) | DHCP restringido: reserva por MAC |
| 30 SERVIDORES | `192.168.30.0/24` | `192.168.30.1` | ZBX-SRV01 (Zabbix), SRV-INTRA01 (Intranet) | Manual |
| 40 GESTIÓN | `192.168.40.0/24` | `192.168.40.1` | SW-CORE01, SW-ACC01, PC-MGMT01 | Manual |

Enlace con el resto del grupo: `192.168.84.2/30` en R1 hacia el proxy E2 (`192.168.84.1`). La dirección de cada equipo, sus servicios y quién llega a cada uno están en [`grupal/EQUIPOS-LAN.md`](grupal/EQUIPOS-LAN.md); el diseño completo, en [`docs/01-diseno-red.md`](docs/01-diseno-red.md).

### Estructura de la carpeta

| Carpeta de E1 | En los demás componentes | Contenido |
|---|---|---|
| `nodos/` | `config/` | Configuración de cada equipo (`rootfs/` refleja la raíz del sistema) y el `aplicar.sh` que la instala |
| `lab/` | `scripts/` | Laboratorio en QEMU: `lab.sh`, `qemuctl.py`, `topologia.conf`, instalación desatendida y enlace con E2 |
| `pruebas/` | `test/` | Matriz de pruebas, su ejecutor, la validación estática y el ensayo sin VM |
| `grupal/` | `scripts/`, `test/` y `docs/` de la integración | Guías, matriz y scripts de la parte grupal |
| `docs/` | `docs/` | Documentación del componente |
| `evidencias/` | `evidencias/` | Capturas, registros (`consola/`, que equivale a `logs/`), capturas de tráfico y resultados |

E1 no es una sola máquina sino diez equipos y el laboratorio que los crea. Los scripts se llaman entre sí por estas rutas, también dentro de las VM (`/mnt/proyecto/nodos/<equipo>/aplicar.sh`), y son las que aparecen en las capturas y en los registros; por eso se conservan los nombres.

---

## 2. Requisitos del Enunciado Oficial

| Requisito | Cómo se cumple | Dónde está |
|---|---|---|
| VLAN y configuración de switches | Switches como VM Debian con un bridge que filtra VLAN; sin VLAN 1 | `nodos/_comun/switch/`, `nodos/sw-*/switch.conf` y `puertos.conf` |
| Troncales 802.1Q y puertos de acceso | Troncales sin VLAN nativa (todo va etiquetado); la VLAN 30 no viaja al switch de acceso | `puertos.conf` (modos `trunk` y `access`) |
| IPv4 manual y subnetting | Un /24 por VLAN, con el tercer octeto igual al número de VLAN; /30 en el enlace con E2 | `docs/01-diseno-red.md`, sección 3 |
| Router inter-VLAN, puerta de enlace de cada VLAN y rutas estáticas | Una subinterfaz por VLAN sobre la troncal; ruta por defecto hacia E2 | `nodos/r1-lan/rootfs/etc/network/` |
| ACL entre redes internas | nftables con política por omisión de descarte, con estado, y registro de cada denegación | `nodos/r1-lan/rootfs/etc/nftables.d/30-acl.nft` |
| Comunicaciones permitidas y bloqueadas demostradas | Matriz de 63 casos que se ejecuta dentro de los clientes | `pruebas/matriz.conf`, `pruebas/probar.sh` |
| DHCP solo en la VLAN 20, nativo de Debian, sin Kea | `isc-dhcp-server` escuchando solo en `trunk0.20` y sin rango dinámico | `nodos/r1-lan/rootfs/etc/dhcp/dhcpd.conf` |
| Solo equipos registrados por MAC; relación MAC/IP en TXT o CSV | Reservas generadas desde `usuarios.csv`; las ACL exigen además el par MAC·IP, así que una IP puesta a mano tampoco sirve | `nodos/r1-lan/rootfs/etc/xelaju/usuarios.csv`, `xelaju-dhcp` |
| El resto de la infraestructura, con direccionamiento estático | Router, switches y servidores con IP fija | `nodos/*/interfaces` |
| Zabbix en la VLAN correspondiente, restringido a la VLAN ADMIN | VLAN 30; tres capas: ACL de R1, cortafuegos del servidor y Apache | `nodos/zbx-srv01/` |
| Zabbix recibe información del Multi-WAN de E3 | Equipo `Router-MultiWAN-E3` con 8 items (entrada y salida de ISP1 e ISP2) y su dashboard | `nodos/zbx-srv01/monitoreo.py` |
| Infraestructura en Debian, por consola y en modo texto | Router, switches y servidores sin escritorio; la web de Zabbix solo para ver y administrar el monitoreo | `docs/02-runbook-individual.md` |
| Scripts de automatización entregados y documentados | Cada script, explicado | `docs/06-scripts.md` |

---

## 3. Configuraciones

En `nodos/` hay una carpeta por equipo. Su `rootfs/` refleja la raíz del sistema: `nodos/r1-lan/rootfs/etc/dhcp/dhcpd.conf` es `/etc/dhcp/dhcpd.conf` en R1-LAN.

### R1-LAN (`nodos/r1-lan/rootfs/`)

| Archivo | Contenido |
|---|---|
| `etc/network/interfaces` | Troncal `trunk0` y subinterfaces `trunk0.10`, `.20`, `.30` y `.40` con la puerta de enlace de cada VLAN |
| `etc/network/modos/individual`, `modos/grupal` | Salida de R1 en cada modo: NAT de QEMU para trabajar sin el grupo, o el enlace `up-squid` hacia E2 con su ruta por defecto |
| `etc/sysctl.d/90-xelaju-router.conf` | Reenvío IPv4, filtro de ruta inversa y sin redirecciones ICMP |
| `etc/nftables.conf` | Carga, en orden, los archivos de `nftables.d/` |
| `etc/nftables.d/00-definiciones.nft` | Redes e interfaces con nombre: VLAN, enlaces de tránsito, redes VPN |
| `etc/nftables.d/10-registrados.nft` | Pares MAC·IP autorizados en la VLAN 20 (lo genera `xelaju-dhcp`) |
| `etc/nftables.d/30-acl.nft` | Las ACL: una cadena por VLAN de origen y una para lo que llega del perímetro |
| `etc/nftables.d/modos/individual.nft`, `grupal.nft` | Lo que cambia con el modo: NAT solo en individual |
| `etc/dhcp/dhcpd.conf`, `etc/default/isc-dhcp-server` | DHCP de la VLAN 20: subred sin `range`, escucha solo en `trunk0.20` |
| `etc/xelaju/usuarios.csv` | Equipos autorizados: `Equipo,Direccion_MAC,IP_reservada` |
| `etc/dhcp/reservas-vlan20.conf` | Un bloque `host` por fila del CSV (lo genera `xelaju-dhcp`) |
| `etc/rsyslog.d/30-xelaju.conf`, `etc/logrotate.d/xelaju` | Registros de las ACL y del DHCP en `/var/log/xelaju/`, legibles solo por administradores |
| `etc/zabbix/zabbix_agent2.d/xelaju-r1.conf` | Items propios de R1 para Zabbix (bloqueos de las ACL, DHCP) |

### Switches, servidores y clientes

| Archivo | Contenido |
|---|---|
| `nodos/_comun/switch/` | El switch: bridge con filtrado de VLAN, servicio de arranque y puerto espejo (SPAN) |
| `nodos/sw-core01/`, `nodos/sw-acc01/` | `switch.conf` (VLAN e IP de gestión) y `puertos.conf` (modo y VLAN de cada puerto) |
| `nodos/zbx-srv01/rootfs/etc/nftables.conf` | Cortafuegos del servidor Zabbix: la web solo desde la VLAN ADMIN |
| `nodos/zbx-srv01/rootfs/etc/apache2/conf-available/zz-xelaju-zabbix.conf` | Restricción de la web en Apache |
| `nodos/srv-intra01/rootfs/` | Intranet: sitio de nginx y página |
| `nodos/pc-*/interfaces` | Direccionamiento de cada cliente (manual, o DHCP en la VLAN 20) |
| `lab/topologia.conf` | El laboratorio: máquinas, MAC, cables y direcciones |

La instalación de Zabbix (base de datos, `zabbix_server.conf`, interfaz web) la hace por consola `nodos/zbx-srv01/aplicar.sh`; equipos, items y dashboards los crea `monitoreo.py` por la API. Detalle en [`docs/03-zabbix.md`](docs/03-zabbix.md).

---

## 4. Scripts

Todos están explicados en [`docs/06-scripts.md`](docs/06-scripts.md). Son idempotentes: repetirlos no duplica reglas, rutas ni entradas.

| Script | Dónde se ejecuta | Qué hace |
|---|---|---|
| `lab/lab.sh` | Host | Orquesta el laboratorio: imagen base, discos, arranque, consola, `aplicar`, `probar`, `capturar` |
| `lab/qemuctl.py` | Host | Habla con cada VM por sus sockets de QEMU |
| `lab/grupal/uplinks-host.sh` | Host (sudo) | Une una tarjeta del host con la VM de R1 para el enlace con E2 |
| `nodos/<equipo>/aplicar.sh` | Dentro de cada VM | Instala paquetes y copia la configuración del equipo |
| `nodos/_comun/comun.sh` | — | Funciones comunes de los `aplicar.sh` |
| `switch-aplicar`, `switch-mostrar`, `switch-span` | Switches | Aplican y muestran VLAN, troncales, tabla MAC y puerto espejo |
| `r1-modo individual\|grupal\|estado` | R1-LAN | Cambia la salida de R1 conservando las ACL |
| `r1-estado` | R1-LAN | Interfaces, rutas, contadores de las ACL, DHCP y servicios |
| `xelaju-dhcp listar\|alta\|baja\|aplicar\|verificar\|log` | R1-LAN | Administra los equipos registrados: del CSV genera las reservas y el conjunto MAC·IP |
| `xelaju-metrica` | R1-LAN | Valores que el agente de Zabbix entrega de R1 |
| `nodos/zbx-srv01/monitoreo.py` | ZBX-SRV01 | Grupos, equipos, items y dashboards de Zabbix, por su API |
| `pruebas/probar.sh`, `pruebas/matriz.conf` | Clientes | Ejecuta los casos de la matriz que tocan a cada equipo |
| `pruebas/validar-estatico.sh`, `pruebas/consistencia.py` | Host | Sintaxis, carga real de las reglas y coherencia entre archivos, sin VM |
| `pruebas/simular-lan.sh` | Host | Ensayo de VLAN, rutas y ACL con espacios de nombres de red, también con dobles de E2, E3, E4 y E5 |
| `grupal/isp-activo.sh` | R1-LAN | Muestra y registra por cuál ISP de E3 sale cada VLAN |
| `grupal/isp-panel.py` | Host | Ese registro, como panel en vivo |

Sin máquinas virtuales (sin root, de segundos a pocos minutos):

```bash
./pruebas/validar-estatico.sh
./pruebas/simular-lan.sh
./pruebas/simular-lan.sh grupal
```

Laboratorio completo (10 VM, unos 8 GB de RAM y 10 GB de disco):

```bash
./lab/lab.sh verificar
./lab/lab.sh base
./lab/lab.sh crear todas
./lab/lab.sh iniciar r1-lan && ./lab/lab.sh aplicar r1-lan
# ...el resto de equipos, en el orden de docs/02-runbook-individual.md
./lab/lab.sh probar
```

Parte grupal, con el equipo de E2 conectado a una tarjeta del host:

```bash
sudo ./lab/grupal/uplinks-host.sh up --squid <tarjeta>
./lab/lab.sh detener r1-lan && ./lab/lab.sh iniciar r1-lan
./lab/lab.sh exec r1-lan r1-modo grupal
```

---

## 5. Funcionamiento

- **Tráfico Inter-VLAN:** todo el tráfico entre VLAN pasa por R1-LAN, que lo evalúa con política por omisión de descarte (`policy drop`) y con estado. Cada denegación queda en `/var/log/xelaju/acl-lan.log` con su origen y su destino.
- **Política entre VLAN:** ADMIN llega a todas las VLAN; USUARIOS solo a la Intranet (`192.168.30.20`, TCP 80 y 443) y a Internet; SERVIDORES sale a Internet pero no inicia conexiones hacia las demás VLAN, salvo el monitoreo de Zabbix; GESTIÓN llega por SSH a los servidores y sale solo para actualizaciones. Matriz completa en `docs/01-diseno-red.md`, sección 6.
- **DHCP restringido:** el servidor no tiene rango dinámico, así que una MAC que no está en `usuarios.csv` no recibe oferta. Un equipo registrado recibe siempre la misma dirección.
- **Tránsito Hacia el Perímetro:** lo que sale de la LAN hacia Internet o la DMZ va por el enlace `192.168.84.0/30` hacia el proxy E2 (`192.168.84.1`). **R1 no hace NAT** en modo grupal: Squid, el firewall y el Multi-WAN ven la dirección real de cada equipo y pueden aplicar sus políticas por origen.
- **Frontera con el firewall (E5):** R1 controla el tráfico entre VLAN y E5 el perímetro. Lo que llega de las redes VPN por el enlace de tránsito ya fue autorizado por E5 y R1 lo deja pasar sin repetir esa política. R1 conserva lo suyo: anti-suplantación, la web de Zabbix solo para la VLAN ADMIN y nada más que VPN y monitoreo desde fuera.
- **Zabbix:** agentes en modo activo (TCP 10051 hacia el servidor). Los equipos de la LAN se registran solos; el de E3 está dado de alta con las claves que publica su agente. R1 y el servidor aceptan ese puerto desde los cuatro enlaces de tránsito.
- **Dos modos en R1:** `individual` (salida por el NAT de QEMU, para trabajar sin el grupo) y `grupal` (enlace con E2, sin NAT), con las mismas ACL entre VLAN.

---

## 6. Evidencias y Pruebas

Resultados, con las capturas que los respaldan (todas en [`evidencias/capturas/`](evidencias/capturas/), con su índice por tema):

| Prueba | Resultado | Captura |
|---|---|---|
| Matriz de 63 casos permitidos y bloqueados, en las VM | 63 PASS (10 de octubre, con R1 en modo grupal) | [23](evidencias/capturas/23-matriz-63-pass.png) |
| VLAN 20 → VLAN 10 | Bloqueado y registrado en R1 | [20](evidencias/capturas/20-users-a-admin-bloqueado.png), [09](evidencias/capturas/09-wireshark-icmp-users-admin-bloqueado.png) |
| VLAN 20 → Intranet | Permitido | [21](evidencias/capturas/21-users-intranet-ok.png) |
| DHCP para una MAC registrada | Recibe su IP reservada | [31](evidencias/capturas/31-dhcp-registrado.png), [07](evidencias/capturas/07-wireshark-dhcp-dora.png) |
| DHCP para una MAC no registrada | Sin oferta; tampoco pasa con una IP puesta a mano | [32](evidencias/capturas/32-dhcp-intruso-sin-oferta.png), [08](evidencias/capturas/08-wireshark-dhcp-intruso-sin-oferta.png) |
| Troncal 802.1Q y puerto de acceso | Tramas etiquetadas en la troncal y sin etiqueta en el acceso | [04](evidencias/capturas/04-wireshark-8021q.png), [05](evidencias/capturas/05-tcpdump-acceso-sin-etiqueta.png), [06](evidencias/capturas/06-tcpdump-troncal-etiquetada.png) |
| Web de Zabbix | `200` desde ADMIN; sin respuesta desde USUARIOS y GESTIÓN | [59](evidencias/capturas/59-zabbix-restringido.png) |
| Dashboards de Zabbix | LAN con datos; Multi-WAN con los 8 items de E3 | [43](evidencias/capturas/43-zabbix-dashboard-lan.png), [44](evidencias/capturas/44-zabbix-dashboard-multiwan.png), [45](evidencias/capturas/45-zabbix-multiwan-latest-data.png) |
| Salida por E2, E5 y E3, sin NAT en R1 | HTTPS y DNS con la IP real; la traza cruza los tres equipos | [50](evidencias/capturas/50-r1-modo-grupal.png), [51](evidencias/capturas/51-ping-vecinos.png) |
| HTTP por Squid (E2) | Interceptado; cada VLAN con su lista | [55](evidencias/capturas/55-squid-listas-por-vlan.png), [52](evidencias/capturas/52-squid-ve-ip-real.png) |
| VPN → LAN (E4 y E5) | R1 registró las llegadas de VPN-ADMIN y VPN-USERS | [53](evidencias/capturas/53-vpn-llega-a-la-lan.png) |
| LAN → WEB01 de la DMZ | `200` desde ADMIN, USUARIOS y SERVIDORES; GESTIÓN bloqueada por R1 | [54](evidencias/capturas/54-lan-ve-web01.png), [56](evidencias/capturas/56-lan-dmz-matriz-grupal.png), [57](evidencias/capturas/57-gestion-bloqueada-dmz.png) |
| ISP en uso y failover del Multi-WAN (E3) | Al caer un ISP, todas las VLAN salen por el otro | [58](evidencias/capturas/58-isp-panel.png) |

Dónde está cada cosa:

| Carpeta o documento | Contenido |
|---|---|
| [`evidencias/capturas/README.md`](evidencias/capturas/README.md) | Las 37 capturas de pantalla, por tema, con lo que demuestra cada una |
| [`evidencias/README.md`](evidencias/README.md) | Lista completa: capturas, registros de consola y capturas de tráfico |
| `evidencias/consola/` | Salidas de consola: instalación de cada equipo, estado de R1, registros de las ACL y del DHCP, rondas de integración con el grupo |
| `evidencias/pcap/` | Capturas de tráfico para Wireshark: troncal, puerto de acceso, DHCP, ICMP bloqueado, salida sin NAT |
| `evidencias/pruebas/`, `evidencias/simulacion/` | Resultado de cada ejecución de la matriz y de los ensayos sin VM |
| [`docs/04-pruebas-y-evidencias.md`](docs/04-pruebas-y-evidencias.md) | Resultados, demostraciones en vivo y las cuatro rondas de integración con el grupo |
| [`grupal/PRUEBAS-FINALES.md`](grupal/PRUEBAS-FINALES.md) | Guion de la sesión final: cada prueba por flujo, con su comando y lo que dio el 10 de octubre |

---

## 7. Observaciones y Pendientes

### Documentación del componente

| Documento | Para qué |
|---|---|
| [`docs/01-diseno-red.md`](docs/01-diseno-red.md) | Topología, direccionamiento, rutas, matriz de seguridad y trazabilidad de cada requisito |
| [`docs/02-runbook-individual.md`](docs/02-runbook-individual.md) | Levantar el laboratorio paso a paso |
| [`docs/03-zabbix.md`](docs/03-zabbix.md) | Zabbix: qué instala el script y cómo se arma el monitoreo |
| [`docs/04-pruebas-y-evidencias.md`](docs/04-pruebas-y-evidencias.md) | Pruebas, demostraciones y capturas |
| [`docs/06-scripts.md`](docs/06-scripts.md) | Cada script documentado |
| [`docs/07-problemas-y-soluciones.md`](docs/07-problemas-y-soluciones.md) | Problemas encontrados y cómo se resolvieron |
| [`docs/diagramas/estudiante1-lan.drawio`](docs/diagramas/estudiante1-lan.drawio) | Diagrama de la LAN |
| [`grupal/EQUIPOS-LAN.md`](grupal/EQUIPOS-LAN.md) | Cada equipo de la LAN con su dirección, sus servicios y quién llega a él |
| [`grupal/CHECKLIST-INTEGRACION.md`](grupal/CHECKLIST-INTEGRACION.md), [`grupal/pruebas-grupales.md`](grupal/pruebas-grupales.md) | Pasos y casos de la integración con el grupo |

### Nombres que aparecen en los documentos y en los comentarios

Durante el desarrollo, el grupo llevó los datos compartidos en un archivo `core/ADDRESSING.yaml` y numeró sus decisiones de arquitectura. Los documentos, los comentarios de las configuraciones y los scripts de E1 los citan con esos nombres. En este repositorio los mismos datos están en [`tablas/`](../tablas/) y el diagrama general en [`topologia/`](../topologia/).

| Nombre | Qué decidió el grupo | Efecto en E1 |
|---|---|---|
| ADR-0001 | No hay enlace directo entre R1 y VPN/DMZ | VPN y DMZ llegan a la LAN por E5 → E2 → R1; a R1 le basta una ruta por defecto |
| ADR-0002 | Plan de direccionamiento, rutas y NAT: una ruta por VLAN, sin resumir; el único NAT es el de E3 | R1 no hace NAT en modo grupal y deja pasar el tráfico VPN que E5 ya autorizó |
| ADR-0003 | Integración de Squid con el Multi-WAN | Ninguno: R1 solo entrega el tráfico a E2 como siguiente salto |
| ADR-0004 | Frontera de seguridad entre E1 y E5 | R1 controla el tráfico entre VLAN; E5, el perímetro |

La sección 8 de `pruebas/consistencia.py` compara E1 con ese `core/ADDRESSING.yaml`; aquí no está, y el script lo indica y la omite.

### Observaciones

- El firewall de E5 no reenvía ping: las pruebas de camino desde la LAN se hacen con `traceroute -T -p 443`.
- WEB01 responde a la LAN solo cuando el equipo de E4 está conectado a su enlace.
- El 10 de octubre el ISP1 estuvo inestable; con el panel del ISP (`grupal/isp-panel.py`) se ve cada caída y el cambio al otro ISP.
- El puente del host con E2 no sobrevive a un reinicio del host: hay que repetir `uplinks-host.sh up` y `r1-modo grupal`.
- Nunca se suben secretos: la contraseña del laboratorio, el preseed generado y las imágenes de disco están en `.gitignore`.

### Pendientes

- Repetir la captura del dashboard del Multi-WAN con los dos ISP llevando tráfico a la vez: en la actual el ISP2 estaba desconectado.
- Sesión final con los cinco equipos a la vez, con el guion de `grupal/PRUEBAS-FINALES.md`. Desde la LAN faltan por ver el cambio en caliente de una lista de Squid (E2) y una alerta del IDS provocada desde la LAN (E5).
