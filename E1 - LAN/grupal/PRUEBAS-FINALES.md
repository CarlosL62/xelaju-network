# Pruebas finales y cierre del proyecto — vistas desde la LAN (E1)

Guion para la sesión final con los cinco equipos conectados: qué probar, con qué comando, qué debe salir, quién decide cada resultado y qué evidencia guardar. Incluye lo que dio cada prueba el **10 de octubre de 2026** para saber de dónde se parte.

- **Entrega:** 13 de octubre de 2026, 15:20, por Classroom.
- **Alcance:** todo lo que se puede comprobar desde la LAN, más lo que E1 necesita ver en los equipos de los compañeros. Los pasos internos de cada uno están en su propia guía: E4 en su `GUIA-PRUEBAS.md`; E2, E3 y E5 en su `README.md`.
- **Dónde se ejecuta:** salvo que se diga otra cosa, los comandos van en el host, desde la carpeta del componente (`E1 - LAN/`). `./lab/lab.sh exec <vm> '<orden>'` ejecuta como root dentro de la VM.
- **Direcciones de cada equipo:** [`EQUIPOS-LAN.md`](EQUIPOS-LAN.md).

Cómo leer los resultados: **sin respuesta** (tiempo agotado, `000`) es el resultado correcto de un bloqueo; **rechazado** significa que el paquete llegó y el destino no tiene ese servicio. Un bloqueo solo cuenta si antes se comprobó que el destino estaba vivo.

## 0. Estado al 10 de octubre

| Bloque | Estado | Detalle |
|---|---|---|
| LAN de E1 (VLAN, rutas, ACL, DHCP, Zabbix) | **Listo** | A las 20:31, 63 PASS de 63. Ver la sección 2 |
| Flujo A: navegación por Squid, firewall y Multi-WAN | **Funciona, con cortes** | HTTPS, DNS, HTTP por Squid, listas por VLAN y failover funcionan. Hoy el ISP1 estuvo inestable: 5 caídas en 1 h 40 min y, mientras estaba activo, falló el 12,6 % de las conexiones TCP 443 que salían por él |
| Flujo B: VPN → LAN | **Funciona** | A las 16:56 R1 registró la matriz de E4: VPN-ADMIN a las cuatro VLAN, VPN-USERS a USUARIOS y a la Intranet, y la web de Zabbix negada |
| Flujo C: DMZ | **Funciona cuando E4 está conectado** | `200` a las 17:20 y a las 20:18 (los 6 casos `g-*` en PASS); a las 19:35 E4 no estaba en el enlace y E5 devolvía "host unreachable" |
| Métricas del Multi-WAN en Zabbix | **Funciona** | Desde las 22:36 llegan los 8 items del agente de E3 y el dashboard los grafica. En la captura el ISP2 marca 0 bps: estaba desconectado en ese momento |
| Capturas de pantalla | **Hechas** | 37 en `evidencias/capturas/`, del 10 de octubre (consola, navegador y Wireshark) |

## 1. Antes de empezar

Los cinco equipos encendidos y cableados a la vez: muchas pruebas "fallan" solo porque un equipo no está.

1. Código al día: `git pull --rebase`.
2. Si el host se reinició, el puente con E2 hay que crearlo de nuevo (pide contraseña):
   ```bash
   sudo ./lab/grupal/uplinks-host.sh up --squid enp7s0
   ```
3. VMs encendidas y R1 en modo grupal. R1 debe arrancar **después** del paso 2:
   ```bash
   ./lab/lab.sh iniciar todas
   ./lab/lab.sh detener r1-lan && ./lab/lab.sh iniciar r1-lan
   ./lab/lab.sh exec r1-lan r1-modo grupal
   ```
4. Comprobación de un minuto. Deben responder E2 y aparecer, en orden, `192.168.84.1` (E2), `192.168.82.1` (E5), `192.168.81.1` (E3) y la puerta del ISP:
   ```bash
   ./lab/lab.sh estado
   ./lab/lab.sh exec r1-lan 'ping -c 3 192.168.84.1; traceroute -T -p 443 -s 192.168.10.1 -n -m 4 -q 1 1.1.1.1'
   ```
5. Monitor del ISP en marcha (solo uno: si ya corre en la consola de R1, no arrancar otro) y panel abierto en otra terminal:
   ```bash
   ./lab/lab.sh exec r1-lan 'setsid nohup /mnt/proyecto/grupal/isp-activo.sh >/dev/null 2>&1 &'
   ./grupal/isp-panel.py
   ```

Si el traceroute se corta: el primer salto que no responde señala el equipo. Después de E2 no sirve `ping`: el firewall de E5 no reenvía ICMP.

## 2. Pruebas de la LAN (E1)

Cubren lo que el enunciado pide a E1: VLAN, switches, troncales, puertos de acceso, direccionamiento, enrutamiento entre VLAN, ACL, DHCP restringido y Zabbix.

| ID | Qué se prueba | Comando | Esperado | Resultado 10-oct |
|---|---|---|---|---|
| L1 | Configuración coherente y cargable | `./pruebas/validar-estatico.sh` | "Validación estática correcta" | Correcta |
| L2 | VLAN, rutas y ACL sin VMs | `./pruebas/simular-lan.sh` y `./pruebas/simular-lan.sh grupal` | 0 FAIL | 61 PASS y 93 PASS; 0 FAIL; 2 omitidas (DHCP) |
| L3 | VLAN y puertos de acceso | `./lab/lab.sh exec sw-core01 'switch-mostrar vlan'` (y `sw-acc01`) | VLAN 30 en p2 y p3, VLAN 40 en p4; en SW-ACC01, VLAN 10 en p1 y VLAN 20 en p2, p3 y p4 | Como se espera |
| L4 | Troncales 802.1Q | `./lab/lab.sh exec sw-core01 'switch-mostrar trunk'` | p0 con 10, 20, 30 y 40; p1 con 10, 20 y 40; sin VLAN nativa | Como se espera |
| L5 | Puerto espejo (SPAN) | `./lab/lab.sh exec sw-core01 'switch-span estado'` | Sesión p0 → p5 | Activa |
| L6 | Puertas de enlace, rutas y reenvío | `./lab/lab.sh exec r1-lan r1-estado` | Una subinterfaz por VLAN, ruta por defecto por `192.168.84.1`, reenvío activo, "NAT en R1: no" | Como se espera; 0 cadenas NAT |
| L7 | ACL: permitido y bloqueado, DHCP y Zabbix (63 casos) | `./lab/lab.sh probar` | 63 PASS | **63 PASS** a las 20:31 (`capturas/23-matriz-63-pass.png`). A las 19:30, 60 PASS y 3 FAIL: U15, M10 y Z11, los casos `internet`. Ver la nota |
| L8 | DHCP restringido | `./lab/lab.sh exec r1-lan 'xelaju-dhcp verificar'` | Siete líneas `[ OK ]` | Las siete |
| L9 | Equipo registrado y equipo intruso | Casos U01, U02 e I01 de L7; `./lab/lab.sh exec r1-lan 'tail -5 /var/log/xelaju/dhcpd.log'` | `DHCPACK` a `.10` y `.11`; para `aa:bb:cc:dd:ee:99`, "no free leases" | Como se espera |
| L10 | Bloqueos registrados | `./lab/lab.sh exec r1-lan 'tail -20 /var/log/xelaju/acl-lan.log'` | Líneas `ACL-DENY` con origen y destino | Presentes; Zabbix cuenta 910 |
| L11 | Web de Zabbix solo para ADMIN | El `curl` de la sección 2 de `docs/03-zabbix.md`, desde PC-ADMIN01, PC-USER01, PC-MGMT01 y el propio servidor | `200`, sin respuesta, sin respuesta y `403` | `200`, `000`, `000`, `403` |
| L12 | Zabbix recibe datos | Web: *Monitoring → Hosts* y dashboard "LAN - Estudiante 1" | Los equipos de la LAN con datos | 9 de 10 a las 19:35; los 10, con `Router-MultiWAN-E3`, desde las 22:36 |
| L13 | Persistencia | Reiniciar el host o una VM y repetir L7 | Todo vuelve solo, salvo el puente del host | Tras el reinicio del host del 10-oct, las VLAN, ACL, DHCP y Zabbix volvieron solos |

**Nota sobre L7.** El caso `internet` pide una página por HTTP con un límite de 10 s. El 4 de octubre pasaron los 63, y hoy a las 20:31 también. A las 19:30 fallaron 3 de 5 por los cortes del ISP1: repetido a mano, 16 de 16 peticiones respondieron `200`, pero dos tardaron 5 s. Si vuelve a ocurrir, mirar primero el panel del ISP y repetir solo esos perfiles: `./lab/lab.sh probar users mgmt zbx`.

Demostraciones en vivo (alta y baja de un equipo en el DHCP, contadores de las ACL, cambio de modo): `docs/04-pruebas-y-evidencias.md`, sección 3.

## 3. Flujo A — navegación desde la LAN

Camino: VLAN → R1 → Squid (E2) → firewall (E5) → Multi-WAN (E3) → Internet.

| ID | Qué se prueba | Dónde y cómo | Esperado | Decide | Resultado 10-oct |
|---|---|---|---|---|---|
| A1 | HTTPS sale directo | PC-ADMIN01, PC-USER01, ZBX-SRV01, PC-MGMT01: `curl -m 6 -o /dev/null -w '%{http_code}\n' https://1.1.1.1` | `301` | E5 | `301` en los cuatro |
| A2 | HTTP pasa por Squid sin configurar proxy | Los mismos: `curl -sI http://example.com/` | `200` y cabecera `Via: … squid` | E2 | `200` con `Via` en los cuatro |
| A3 | Lista de ADMIN | PC-ADMIN01: `http://www.facebook.com/` e `http://www.ilovepdf.com/` | `403`; `http://www.youtube.com/` pasa | E2 | Como se espera |
| A4 | Lista de USUARIOS | PC-USER01: `http://www.facebook.com/` y `http://www.youtube.com/` | `403`; `http://www.ilovepdf.com/` pasa | E2 | Como se espera |
| A5 | Cambiar una lista durante la calificación | E2 agrega un dominio con su `add_domain.sh`; se repite A3 o A4 con ese dominio | Bloqueado sin reiniciar Squid ni tocar `squid.conf` | E2 | Sin probar |
| A6 | Portal de Squid solo para ADMIN | `http://192.168.84.1:8080/` desde PC-ADMIN01 y desde PC-USER01 | `200` y `403` | E2 | `200`; `403` desde USUARIOS y SERVIDORES |
| A7 | R1 no hace NAT | Portal de Squid; `./lab/lab.sh capturar r1-lan up-squid 20` | Aparecen `192.168.10.50`, `192.168.20.10`, `192.168.30.10`, `192.168.40.10` | E1 | En la captura salen esas cuatro direcciones, ninguna traducida; el portal muestra `192.168.20.10` (`capturas/52-squid-ve-ip-real.png`) |
| A8 | Un intruso no navega | Caso I06 e I07 de L7 | Bloqueado en R1 | E1 | PASS |
| A9 | Política por origen en el Multi-WAN | Panel del ISP con los dos ISP activos | TCP 443 de ADMIN y USUARIOS por ISP1; TCP 443 de SERVIDORES y DNS de USUARIOS por ISP2 | E3 | Como se espera |
| A10 | Balanceo | Panel: clases sin política (DNS de ADMIN, SERVIDORES y GESTIÓN; TCP 443 de GESTIÓN) | La barra alterna los dos colores | E3 | Alterna |
| A11 | Failover y recuperación | E3 desconecta un ISP y lo vuelve a conectar; mirar el panel | `SOLO-ISP2` o `SOLO-ISP1` en uno o dos ciclos, todo sigue en `OK`; al volver, `NORMAL` | E3 | Probado en los dos sentidos el 4-oct. Hoy hubo varios failover automáticos al caer el ISP1; se ven en `capturas/58-isp-panel.png` |
| A12 | Registro del ISP usado | E3 muestra su `failover.log` y su registro de políticas; E1, `evidencias/consola/isp-activo-*.log` | Las horas coinciden | E3 | Sin contrastar con E3 |

Los comandos de A1 a A4 se lanzan desde el host así: `./lab/lab.sh exec pc-user01 'curl -s -m 8 -o /dev/null -w "%{http_code}\n" http://www.youtube.com/'`.

Límite conocido: las listas de Squid solo actúan sobre HTTP; por HTTPS no se filtra nada.

## 4. Flujo B — acceso por VPN

Camino: Internet → firewall → VPN (E4) → firewall → Squid (solo reenvía) → R1 → VLAN. La política la aplica E5; R1 deja pasar lo autorizado y mantiene cerrada la web de Zabbix.

E4 lanza su matriz (`vpn_matrix.sh admin1` y después `user1`) o prueba con el teléfono. Desde la LAN se mira lo que llega:

```bash
./lab/lab.sh exec r1-lan 'nft list chain inet xelaju desde_perimetro | grep -E "VPN|ZBXWEB"'
./lab/lab.sh exec r1-lan 'grep -a "r1-lan kernel: ACL-ALLOW VP[N]" /var/log/xelaju/acl-lan.log | tail -8'
```

| ID | Qué se prueba (caso de E4) | Esperado en el cliente | Qué debe verse en R1 | Decide | Resultado 10-oct |
|---|---|---|---|---|---|
| B1 | VPN-ADMIN → ping a PC-ADMIN01 (A1) | Responde | `SRC=10.200.10.10 DST=192.168.10.50` | E5 | Registrado a las 16:56 |
| B2 | VPN-ADMIN → SSH de PC-USER01 (A2) | Conecta | `DST=192.168.20.10 … DPT=22` | E5 | Registrado |
| B3 | VPN-ADMIN → ping a Zabbix (A3) | Responde | `DST=192.168.30.10` | E5 | Registrado |
| B4 | VPN-ADMIN → Intranet (A4) | `200` | `DST=192.168.30.20 … DPT=80` | E5 | Registrado |
| B5 | VPN-ADMIN → SSH de SW-CORE01 (A5) | Conecta | `DST=192.168.40.2 … DPT=22` | E5 | Registrado |
| B6 | VPN-ADMIN → web de Zabbix (A6) | Sin respuesta | Sube `ACL-DENY PERIMETRO->ZBXWEB` | **R1** | 6 paquetes negados |
| B7 | VPN-USERS → ping a PC-USER01 (U1) | Responde | `SRC=10.200.20.10 DST=192.168.20.10` | E5 | Registrado |
| B8 | VPN-USERS → Intranet por HTTP y HTTPS (U2, U3) | `200` | `DST=192.168.30.20`, puertos 80 y 443 | E5 | Registrados los dos |
| B9 | VPN-USERS → ADMIN, GESTIÓN, SSH de la Intranet (U4 a U8) | Sin respuesta | **Nada**: lo corta E5 antes de R1 | E5 | A R1 no llegó nada de eso |
| B10 | Internet de los clientes VPN por el Multi-WAN | Navega con el túnel activo | — | E4 y E3 | Lo prueba E4 (su guía, 5.5) |

Para que B9 sea válido, B1 a B5 deben haber respondido antes: demuestran que esos destinos están vivos.

## 5. Flujo C — DMZ y ngrok

| ID | Qué se prueba | Dónde y cómo | Esperado | Decide | Resultado 10-oct |
|---|---|---|---|---|---|
| C1 | La LAN abre WEB01 | PC-ADMIN01, PC-USER01, ZBX-SRV01: `curl -m 6 -o /dev/null -w '%{http_code}\n' http://172.16.10.10:8081/` | `200` | E5 | `200` a las 17:20 y a las 20:18 (`capturas/54-lan-ve-web01.png`). A las 19:35, "host unreachable" de E5: E4 no estaba conectado |
| C2 | GESTIÓN no llega a la DMZ | PC-MGMT01: el mismo `curl` | Sin respuesta; en R1, `ACL-DENY MGMT->?` | **R1** | Sin respuesta y registrado |
| C3 | De la LAN a la DMZ solo el puerto de WEB01 | PC-USER01: `nc -zv -w 4 172.16.10.10 22` | Sin respuesta | E5 | PASS (GL4) |
| C4 | Los seis casos anteriores de una vez | Perfiles `g-*` (comando abajo) | GL1 a GL6 PASS | — | **Los 6 PASS** a las 20:18 (`capturas/56-lan-dmz-matriz-grupal.png`). A las 19:34, sin E4, 3 PASS y 3 FAIL |
| C5 | La DMZ no inicia conexiones hacia la LAN | E4: `vpn_matrix.sh dmz` (D2, D3, D4) | Sin respuesta | E5; R1 también lo niega | Lo prueba E4 |
| C6 | WEB01 publicado por ngrok | E4: su guía, D-e y D-f | Carga desde datos móviles | E4 | Lo prueba E4 |

Perfiles `g-*`, uno por VM:

```bash
for p in "g-admin pc-admin01" "g-users pc-user01" "g-mgmt pc-mgmt01" "g-zbx zbx-srv01"; do set -- $p; ./lab/lab.sh exec $2 "XJ_MATRIZ=/mnt/proyecto/grupal/matriz-grupal.conf /bin/bash /mnt/proyecto/pruebas/probar.sh $1"; done
```

## 6. Seguridad perimetral, IDS y capturas

| ID | Qué se prueba | Cómo | Esperado | Quién | Resultado 10-oct |
|---|---|---|---|---|---|
| S1 | Internet no entra a la LAN ni a la DMZ | E4, guía D-a; E5 muestra sus registros `E5-DENY-INET2LAN` y `E5-DENY-INET2DMZ` | Sin respuesta y registrado | E5 | Sin ver desde E1 |
| S2 | E5 no repite las ACL internas ni R1 la política VPN | `./pruebas/simular-lan.sh grupal`, comprobaciones "Sin E5…" | Sin E5, R1 sigue negando DMZ → LAN y la web de Zabbix | E1 | 0 fallos |
| S3 | Alerta del IDS con una prueba controlada | Acordar con E5. Desde PC-USER01: `ping -c 5 192.168.82.1`; E5 tiene una regla local para ICMP eco (SID 1000001) | Alerta en el registro de Suricata de E5 | E5 | Sin probar |
| S4 | Captura con SPAN | `./lab/lab.sh capturar sw-core01 p5 20` y abrir el `.pcap` en Wireshark | Tramas de la troncal con su etiqueta 802.1Q | E1 | Hecha el 3-oct (`evidencias/pcap/`) |
| S5 | Captura de la salida de la LAN | `./lab/lab.sh capturar r1-lan up-squid 20` | Direcciones reales de las VLAN | E1 | `evidencias/pcap/salida-sin-nat.pcap` |

## 7. Monitoreo del Multi-WAN

| ID | Qué se prueba | Cómo | Esperado | Quién | Resultado 10-oct |
|---|---|---|---|---|---|
| M1 | El agente de E3 llega al servidor | En E3: `nc -zv -w 4 192.168.30.10 10051` | Conecta | E5 y R1 | Conecta, con origen `192.168.81.1`; R1 cuenta sus paquetes |
| M2 | Zabbix recibe ISP1 e ISP2, entrada y salida | Web: *Monitoring → Latest data*, host `Multi-WAN (Estudiante 3)` | Los 8 items con valores | E3 | **Llegan los 8** desde las 22:36 (`capturas/45-zabbix-multiwan-latest-data.png`). ISP2 en 0 bps: estaba desconectado |
| M3 | Dashboard del Multi-WAN | Web: dashboard "Multi-WAN - Estudiante 3" | Gráficas de los dos ISP | E1 y E3 | Grafica el tráfico (`capturas/44-zabbix-dashboard-multiwan.png`), tras corregir en `monitoreo.py` el nombre del equipo en las gráficas |

E3 lo dejó funcionando el 10 de octubre con su `scripts/setup_zabbix.sh`. Si deja de llegar: en E3, `systemctl status zabbix-agent`; en R1, `grep -a 10051 /var/log/xelaju/acl-lan.log`.

## 8. Evidencias que faltan

Lista completa en `evidencias/README.md`. Lo que todavía hay que reunir:

- [x] Capturas de pantalla de `evidencias/capturas/`: 37, del 10 de octubre. Las de consola se hicieron ejecutando cada orden en un terminal del host; las del navegador son la pantalla de PC-ADMIN01 y PC-USER01; las de Wireshark abren los `.pcap` de `evidencias/pcap/`.
- [x] `./lab/lab.sh probar` con 63 PASS en modo grupal (`23`).
- [x] Perfiles `g-*` con los 6 PASS y E4 conectado (`56`).
- [x] Portal de Squid mostrando las direcciones de la LAN (`52`).
- [x] Llegadas de VPN registradas en R1 (`53`).
- [x] Zabbix con datos del Multi-WAN (`44` y `45`). Falta repetirla con los dos ISP llevando tráfico a la vez.
- [ ] Panel del ISP durante un failover provocado, con la hora que dé E3 (A11 y A12).
- [ ] Alerta del IDS provocada desde la LAN (S3).
- [ ] Las capturas que solo puede sacar cada compañero en su equipo: registro de Squid (E2), `failover.log` (E3), matriz de VPN y ngrok (E4), registros del firewall y del IDS (E5).

Ya guardadas, además de las capturas: `consola/vpn-llegadas-r1-20261010.log`, `consola/isp-activo-20261004.log` y `-20261010.log`, `consola/integracion-grupal-*.log`, `pcap/salida-sin-nat.pcap`, `pruebas/` y `simulacion/` del 10 de octubre.

## 9. Entregables del enunciado

| Entregable | Dónde está para E1 | Estado |
|---|---|---|
| Archivos de configuración y scripts | `nodos/`, `lab/`, `pruebas/`, `grupal/` | En el repositorio |
| Tabla de direccionamiento | `docs/01-diseno-red.md`, sección 3; resumen en `grupal/EQUIPOS-LAN.md` | Hecha |
| Tabla de rutas | `docs/01-diseno-red.md`, sección 5 | Hecha |
| Matriz de seguridad | `docs/01-diseno-red.md`, sección 6 | Hecha; coincide con `30-acl.nft` |
| Diagrama de la LAN | `docs/diagramas/estudiante1-lan.drawio` | Hecho |
| Diagrama general del grupo | `topologia/xelaju-network.drawio` | Por revisar entre todos |
| Evidencias | `evidencias/`; índice de las capturas en `evidencias/capturas/README.md` | Completas |
| Documentación individual | Se entrega por Classroom | La entrega cada estudiante |
| Documentación general del grupo | — | Por acordar quién la arma |

## 10. Pendientes y riesgos antes del 13 de octubre

| Pendiente | De quién | Por qué importa |
|---|---|---|
| ISP1 inestable | E3 | Con los dos ISP activos fallan conexiones; con solo el ISP2, casi ninguna (1 %). Si se repite el día de la entrega, conviene saber explicarlo o mostrar el panel |
| E4 presente durante las pruebas | E4 | Sin su equipo en el enlace fallan C1, C4 y todo el flujo B |
| La VPN solo puede iniciarse por el ISP1 | E4 y E3 | Lo documenta E4; con el ISP1 caído no entran clientes nuevos |
| Cambiar una lista de Squid en caliente (A5) y alerta del IDS (S3) | E2 y E5 | Son demostraciones que pide el enunciado y no se han visto desde la LAN |
| El puente del host no sobrevive a un reinicio | E1 | Repetir el paso 2 de la sección 1 antes de la defensa |
| Bytes nulos en `acl-lan.log` | E1 | Usar `grep -a`; `tail` no se ve afectado |

## 11. Orden sugerido para la sesión final

1. Sección 1 completa y panel del ISP abierto (10 min).
2. LAN: L7 y repasar en vivo las órdenes de las capturas de L3 a L12 (20 min).
3. Flujo A: A1 a A8 con E2; A9 a A12 con E3, que desconecta y reconecta cada ISP (25 min).
4. Flujo B: E4 corre `admin1` y `user1`; E1 guarda lo que registra R1 (15 min).
5. Flujo C: C1 a C4 desde la LAN; C5 y C6 los muestra E4 (10 min).
6. Seguridad y monitoreo: S1, S3, M1 a M3 (15 min).
7. Guardar evidencias, anotar aquí el resultado final de cada caso y detener el monitor: `./lab/lab.sh exec r1-lan "pkill -f '[i]sp-activo.sh'"`.
