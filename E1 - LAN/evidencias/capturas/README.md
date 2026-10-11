# Capturas de pantalla de E1, por tema

**Fecha de las capturas:** 2026-10-10, con los cinco equipos del grupo conectados
**Responsable:** Estudiante 1 (E1)

Índice de las imágenes de esta carpeta, con lo que demuestra cada una. La lista completa de evidencias, con los registros de consola y las capturas de tráfico, está en [`../README.md`](../README.md).

Cómo se hicieron: las de consola, ejecutando cada orden en un terminal del host del laboratorio (se ve la orden y su salida); las del navegador son la pantalla de PC-ADMIN01 y PC-USER01; las de Wireshark abren los `.pcap` de [`../pcap/`](../pcap/).

Las direcciones de cada equipo que aparece en las capturas: [`grupal/EQUIPOS-LAN.md`](../../grupal/EQUIPOS-LAN.md).

## 1. Switches, VLAN y troncales 802.1Q

| Captura | Qué demuestra |
|---|---|
| [01-sw-core01-vlan](01-sw-core01-vlan.png) | VLAN y puertos de acceso del switch de núcleo; troncales p0 y p1 sin VLAN nativa |
| [02-sw-acc01-vlan](02-sw-acc01-vlan.png) | Lo mismo en el switch de acceso (VLAN 10 y 20) |
| [03-sw-core01-mac](03-sw-core01-mac.png) | Tabla MAC: cada equipo en su VLAN y su puerto |
| [04-wireshark-8021q](04-wireshark-8021q.png) | Trama de la troncal en Wireshark con la etiqueta 802.1Q abierta (tipo `0x8100`, VLAN 10) |
| [05-tcpdump-acceso-sin-etiqueta](05-tcpdump-acceso-sin-etiqueta.png) | En un puerto de acceso las tramas van sin etiqueta |
| [06-tcpdump-troncal-etiquetada](06-tcpdump-troncal-etiquetada.png) | En la troncal, las mismas tramas llevan `802.1Q` y su VLAN |

## 2. Router, direccionamiento y rutas

| Captura | Qué demuestra |
|---|---|
| [10-r1-estado](10-r1-estado.png) | Subinterfaces por VLAN, tabla de rutas, reenvío, paquetes permitidos y bloqueados por cadena, DHCP y servicios de R1 |
| [11-ip-de-cada-equipo](11-ip-de-cada-equipo.png) | Dirección IPv4 de cada equipo de la LAN |
| [50-r1-modo-grupal](50-r1-modo-grupal.png) | R1 en modo grupal: enlace con E2, ruta por defecto y **sin NAT** |
| [51-ping-vecinos](51-ping-vecinos.png) | Ping a E2 y traza TCP 443 que cruza E2, E5 y E3 hasta el ISP |

## 3. ACL entre VLAN

| Captura | Qué demuestra |
|---|---|
| [20-users-a-admin-bloqueado](20-users-a-admin-bloqueado.png) | USUARIOS no llega a ADMIN y R1 registra el bloqueo con origen y destino |
| [21-users-intranet-ok](21-users-intranet-ok.png) | USUARIOS sí abre la Intranet (servicio permitido de SERVIDORES) |
| [22-acl-contadores-usuarios](22-acl-contadores-usuarios.png) | Reglas de la cadena `desde_users` con sus contadores |
| [23-matriz-63-pass](23-matriz-63-pass.png) | Los 63 casos de permitido y bloqueado, en modo grupal: 63 PASS |
| [09-wireshark-icmp-users-admin-bloqueado](09-wireshark-icmp-users-admin-bloqueado.png) | En Wireshark: cuatro pings de USUARIOS a ADMIN, ninguna respuesta |

## 4. DHCP restringido de la VLAN 20

| Captura | Qué demuestra |
|---|---|
| [30-dhcp-listar](30-dhcp-listar.png) | Equipos registrados por MAC y verificación del servicio (sin rango dinámico, solo en la VLAN 20) |
| [31-dhcp-registrado](31-dhcp-registrado.png) | Un equipo registrado recibe su IP reservada: las cuatro fases en el cliente y en el servidor |
| [32-dhcp-intruso-sin-oferta](32-dhcp-intruso-sin-oferta.png) | Una MAC no registrada no recibe oferta ni puede usar una IP puesta a mano |
| [33-dhcp-alta-baja](33-dhcp-alta-baja.png) | Alta de un equipo (recibe dirección) y baja (deja de tener red) |
| [07-wireshark-dhcp-dora](07-wireshark-dhcp-dora.png) | En Wireshark: Release, Discover, Offer, Request y ACK de un equipo registrado |
| [08-wireshark-dhcp-intruso-sin-oferta](08-wireshark-dhcp-intruso-sin-oferta.png) | En Wireshark: el intruso repite el Discover y nadie contesta |

## 5. Zabbix

| Captura | Qué demuestra |
|---|---|
| [40-zabbix-login-admin](40-zabbix-login-admin.png) | La web de Zabbix abierta desde PC-ADMIN01 |
| [41-zabbix-bloqueado-users](41-zabbix-bloqueado-users.png) | La misma dirección desde PC-USER01: tiempo agotado |
| [59-zabbix-restringido](59-zabbix-restringido.png) | `200` desde ADMIN, sin respuesta desde USUARIOS y GESTIÓN, `403` desde el propio servidor |
| [42-zabbix-hosts](42-zabbix-hosts.png) | Los equipos vigilados |
| [43-zabbix-dashboard-lan](43-zabbix-dashboard-lan.png) | Dashboard "LAN - Estudiante 1": tráfico por VLAN, disponibilidad, problemas y contadores de DHCP |
| [44-zabbix-dashboard-multiwan](44-zabbix-dashboard-multiwan.png) | Dashboard "Multi-WAN - Estudiante 3" con los datos del agente de E3: entrada y salida de ISP1 e ISP2. El ISP2 marca 0 bps porque estaba desconectado en ese momento |
| [45-zabbix-multiwan-latest-data](45-zabbix-multiwan-latest-data.png) | Los 8 items del Multi-WAN con valores |
| [44-zabbix-dashboard-multiwan-sin-datos](44-zabbix-dashboard-multiwan-sin-datos.png) | El mismo dashboard horas antes, cuando el agente de E3 aún no enviaba nada |

## 6. Integración con el grupo

| Captura | Qué demuestra | Con quién |
|---|---|---|
| [55-squid-listas-por-vlan](55-squid-listas-por-vlan.png) | HTTPS directo, HTTP por Squid y la lista que corresponde a cada VLAN | E2 |
| [52-squid-ve-ip-real](52-squid-ve-ip-real.png) | El portal de Squid, abierto desde ADMIN, muestra la IP real `192.168.20.10` | E2 |
| [58-isp-panel](58-isp-panel.png) | Por cuál ISP sale cada VLAN, y los cambios de estado cuando cae el ISP1 | E3 |
| [53-vpn-llega-a-la-lan](53-vpn-llega-a-la-lan.png) | Llegadas de VPN-ADMIN y VPN-USERS registradas en R1; la web de Zabbix negada también por VPN | E4 y E5 |
| [54-lan-ve-web01](54-lan-ve-web01.png) | PC-USER01 abre WEB01 de la DMZ | E4 y E5 |
| [56-lan-dmz-matriz-grupal](56-lan-dmz-matriz-grupal.png) | Los seis casos de la LAN hacia la DMZ en PASS | E4 y E5 |
| [57-gestion-bloqueada-dmz](57-gestion-bloqueada-dmz.png) | GESTIÓN no llega a la DMZ: lo niega R1 y queda registrado | — |

## 7. Validación

| Captura | Qué demuestra |
|---|---|
| [60-validacion-estatica](60-validacion-estatica.png) | Final de la validación estática, incluida la coherencia con `core/ADDRESSING.yaml` |

## Lo que falta

- Repetir la captura del dashboard del Multi-WAN con los dos ISP llevando tráfico a la vez: en la actual el ISP2 estaba desconectado.

El guion de las pruebas finales, con lo que dio cada una el 10 de octubre, está en [`grupal/PRUEBAS-FINALES.md`](../../grupal/PRUEBAS-FINALES.md).
