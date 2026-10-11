# Evidencias

Esta carpeta se comparte con las VMs como `/mnt/evidencias` (con escritura), así que lo que un equipo guarde ahí aparece aquí.

| Subcarpeta | Contenido | Quién la llena |
|---|---|---|
| `simulacion/` | Resultado del ensayo sin VMs | `./pruebas/simular-lan.sh` |
| `pruebas/` | Resultado de cada perfil de la matriz y resumen por ejecución | `./lab/lab.sh probar`, `probar.sh` |
| `pcap/` | Capturas de los cables | `./lab/lab.sh capturar` |
| `capturas/` | Capturas de pantalla; índice por tema, con lo que demuestra cada una, en [`capturas/README.md`](capturas/README.md) | a mano |
| `consola/` | Salidas de órdenes guardadas en texto | `./lab/lab.sh aplicar <vm>` deja `<vm>-aplicar.log`; `grupal/isp-activo.sh`, `isp-activo-AAAAMMDD.log`; el resto, a mano (ver abajo) |
| `tmp/` | Pruebas sueltas; no se versiona | a mano |

Para guardar una salida de consola desde una VM:

```bash
sudo r1-estado | tee /mnt/evidencias/consola/r1-estado.txt
```

O desde el host: `./lab/lab.sh exec r1-lan r1-estado > evidencias/consola/r1-estado.txt`

## Lista de evidencias a reunir

Marcar cada una al guardarla. El detalle de cómo obtenerlas está en `docs/04-pruebas-y-evidencias.md`.

Las salidas de texto y las capturas de tráfico marcadas `[x]` se guardaron el 3 y el 4 de octubre de 2026. Las capturas de pantalla (`capturas/`) son del 10 de octubre, con los cinco equipos del grupo conectados: las de consola, ejecutando cada orden en un terminal del host; las del navegador, tomadas de la pantalla de PC-ADMIN01 y PC-USER01. Las de Wireshark (`04`, `07`, `08` y `09`) abren los `.pcap` de `pcap/`. Están todas las de la lista.

### Capa 2: VLAN y switches

- [x] `capturas/01-sw-core01-vlan.png` — `switch-mostrar vlan` y `switch-mostrar trunk` en SW-CORE01
- [x] `capturas/02-sw-acc01-vlan.png` — lo mismo en SW-ACC01
- [x] `capturas/03-sw-core01-mac.png` — `switch-mostrar mac`
- [x] `consola/sw-core01-config.txt`, `consola/sw-acc01-config.txt` — `switch-mostrar todo` y `switch-mostrar config`
- [x] `pcap/troncal-etiquetada.pcap` — troncal SW-CORE01 p0 con las VLAN 10, 20, 30 y 40
- [x] `pcap/acceso-vlan10-sin-etiqueta.pcap` — puerto de acceso de PC-ADMIN01 (SW-ACC01 p1): las mismas tramas, sin etiqueta
- [x] `pcap/span-copia-de-la-troncal.pcap` — lo que sale por el puerto espejo p5
- [x] `capturas/04-wireshark-8021q.png` — una trama con su etiqueta 802.1Q abierta en Wireshark
- [x] `capturas/05-tcpdump-acceso-sin-etiqueta.png` — puerto de acceso sin etiqueta

### Capa 3: router y rutas

- [x] `capturas/10-r1-estado.png` — `sudo r1-estado`
- [x] `consola/r1-estado.txt` — la misma salida, en texto
- [x] `consola/r1-rutas-individual.txt` — `ip route` en modo individual
- [x] `consola/r1-lan-cambio-de-modo.log` — `r1-modo grupal` (interfaces, rutas, sin NAT) y vuelta a individual
- [x] `consola/persistencia-tras-reinicio.log` — R1 y SW-CORE01 recién reiniciados, sin ejecutar nada
- [x] `capturas/11-ip-de-cada-equipo.png` — `ip -br addr` en cada equipo
- [x] `consola/ip-de-cada-equipo.txt` — lo mismo, en texto

### ACL

- [x] `pruebas/resumen-*.txt` — `./lab/lab.sh probar` sin fallos (63 PASS), antes y después de reiniciar R1 y SW-CORE01
- [x] `consola/r1-nft-ruleset.txt` — `sudo nft list ruleset` con contadores, después de las pruebas
- [x] `consola/r1-acl-lan.log.txt` — `sudo tail -50 /var/log/xelaju/acl-lan.log`
- [x] `capturas/20-users-a-admin-bloqueado.png` — ping de PC-USER01 a PC-ADMIN01 sin respuesta
- [x] `capturas/21-users-intranet-ok.png` — PC-USER01 abre la Intranet
- [x] `pcap/icmp-users-admin-sin-respuesta.pcap` — en el puerto de PC-USER02: 4 peticiones a 192.168.10.50 y ninguna respuesta (filtro `ip.addr == 192.168.10.50`; el otro ICMP que aparece es el ping de monitoreo de Zabbix, que sí está permitido)

### DHCP restringido

- [x] `capturas/30-dhcp-listar.png` — `sudo xelaju-dhcp listar` y `verificar`
- [x] `capturas/31-dhcp-registrado.png` — PC-USER01 recibe 192.168.20.10
- [x] `capturas/32-dhcp-intruso-sin-oferta.png` — `dhclient -v` en PC-INTRUSO
- [x] `capturas/33-dhcp-alta-baja.png` — alta del intruso (recibe .13) y baja
- [x] `consola/r1-dhcpd.log.txt` — `sudo tail -40 /var/log/xelaju/dhcpd.log`
- [x] `consola/r1-registro-dhcp.txt` — `sudo xelaju-dhcp listar` y `log`
- [x] `consola/verificacion-zabbix-dhcp-acl.log` — DORA de los equipos registrados y DISCOVER del intruso sin oferta
- [x] `pcap/dhcp-dora-registrado.pcap` — PC-USER02 suelta su dirección y la vuelve a pedir
- [x] `pcap/dhcp-discover-intruso.pcap` — PC-INTRUSO pide dirección y nadie le contesta

### Zabbix

- [x] `capturas/40-zabbix-login-admin.png` — web abierta desde PC-ADMIN01
- [x] `capturas/41-zabbix-bloqueado-users.png` — la misma dirección desde PC-USER01
- [x] `capturas/42-zabbix-hosts.png` — *Monitoring → Hosts* con los equipos de la LAN
- [x] `capturas/43-zabbix-dashboard-lan.png` — dashboard "LAN - Estudiante 1"
- [x] `capturas/44-zabbix-dashboard-multiwan.png` — dashboard "Multi-WAN - Estudiante 3" con datos del agente de E3 (el ISP2 en 0 bps: estaba desconectado en ese momento)
- [x] `capturas/45-zabbix-multiwan-latest-data.png` — *Latest data* del equipo del Multi-WAN: los 8 items con valores
- [x] `consola/zbx-servicios.txt` — servicios, puertos y cortafuegos de ZBX-SRV01
- [x] `consola/zbx-srv01-aplicar.log` — instalación completa, con la salida de `monitoreo.py`

### Parte grupal

- [x] `capturas/50-r1-modo-grupal.png` — `sudo r1-modo estado`
- [x] `consola/integracion-grupal-e2-e5-e3.log` — integración real del 4 de octubre: puente del host, R1 en modo grupal, HTTPS y traceroute por E2, E5 y E3, y lo que aún falla (HTTP por Squid, WEB01)
- [x] `capturas/51-ping-vecinos.png` — ping de R1 y de PC-ADMIN01 a 192.168.84.1 (E2), y el traceroute TCP que cruza E2, E5 y E3
- [x] `capturas/53-vpn-llega-a-la-lan.png` — contador de `ACL-ALLOW VPN->LAN` en `desde_perimetro`
- [x] `capturas/54-lan-ve-web01.png` — PC-USER01 abre WEB01 de la DMZ
- [x] `capturas/06-tcpdump-troncal-etiquetada.png` — la troncal p0 de SW-CORE01: tramas con `802.1Q` y su VLAN
- [x] `capturas/07-wireshark-dhcp-dora.png` — `pcap/dhcp-dora-registrado.pcap` con el filtro `dhcp`: Release, Discover, Offer, Request y ACK de PC-USER02
- [x] `capturas/08-wireshark-dhcp-intruso-sin-oferta.png` — `pcap/dhcp-discover-intruso.pcap`: el intruso repite el Discover y nadie le ofrece dirección
- [x] `capturas/09-wireshark-icmp-users-admin-bloqueado.png` — `pcap/icmp-users-admin-sin-respuesta.pcap`: cuatro peticiones de USUARIOS a ADMIN, ninguna respuesta
- [x] `capturas/22-acl-contadores-usuarios.png` — cadena `desde_users` de R1 con sus contadores
- [x] `capturas/23-matriz-63-pass.png` — `./lab/lab.sh probar` completo en modo grupal: 63 PASS
- [x] `capturas/44-zabbix-dashboard-multiwan-sin-datos.png` — el dashboard del Multi-WAN existe pero no recibe datos del agente de E3
- [x] `capturas/55-squid-listas-por-vlan.png` — HTTPS directo, HTTP por Squid y las listas de ADMIN y de USUARIOS
- [x] `capturas/56-lan-dmz-matriz-grupal.png` — los seis casos `g-*` de la LAN hacia la DMZ en PASS
- [x] `capturas/57-gestion-bloqueada-dmz.png` — GESTIÓN no llega a WEB01 y R1 lo registra
- [x] `capturas/58-isp-panel.png` — `grupal/isp-panel.py`: por cuál ISP de E3 sale cada VLAN
- [x] `capturas/59-zabbix-restringido.png` — la web de Zabbix: `200` desde ADMIN, sin respuesta desde USUARIOS y GESTIÓN, `403` desde el propio servidor
- [x] `capturas/60-validacion-estatica.png` — final de `./pruebas/validar-estatico.sh`
- [x] `simulacion/simulacion-grupal-*.txt` — ensayo con dobles de E2, E5, E3 y E4 (no sustituye a la integración real)
- [x] `capturas/52-squid-ve-ip-real.png` — registro de Squid con origen 192.168.20.10
- [x] `pruebas/g-*.txt` — perfiles de `grupal/matriz-grupal.conf` contra los equipos reales (4 de octubre: a las 21:13 y a las 23:04, 3 PASS y 3 FAIL, los de LAN → WEB01; a las 23:24, los 6 PASS)
- [x] `consola/integracion-grupal-squid-dmz-isp.log` — segunda ronda del 4 de octubre: Squid desde cada VLAN, portal de E2, LAN → WEB01 con la respuesta de E5, ISP en uso y estado de Zabbix
- [x] `consola/isp-activo-20261004.log` — registro de `grupal/isp-activo.sh`: con los dos ISP activos y durante el failover real de las 22:40–23:05
- [x] `consola/vpn-llegadas-r1-20261010.log` — llegadas de VPN-ADMIN y VPN-USERS registradas en R1 el 10 de octubre, contadores de `desde_perimetro` y negación de la web de Zabbix por VPN
- [x] `consola/isp-activo-20261010.log` — registro del ISP en uso del 10 de octubre (el ISP2 por otra puerta de salida)
- [x] `consola/integracion-grupal-failover-isp.log` — tercera ronda del 4 de octubre: cambios de estado en el failover, pruebas con el ISP1 desconectado, Squid, LAN → WEB01 y Zabbix
- [x] `pcap/salida-sin-nat.pcap` — el enlace de R1 con E2 (`./lab/lab.sh capturar r1-lan up-squid 20`): los equipos de las cuatro VLAN salen con su dirección real, sin NAT
