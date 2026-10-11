# Evidencias de Verificación — E4 (WireGuard VPN y DMZ)

**Componente:** E4 — Servidor WireGuard (`wg0`), DMZ (WEB01) y publicación con ngrok<br>
**Responsable:** Estudiante 4<br>
**Curso:** Redes de Computadoras 2 — CUNOC / USAC<br>
**Fechas de recolección:** del 2026-10-04 al 2026-10-11

Índice de ubicación de las evidencias técnicas del componente E4. Las explicaciones y conclusiones se presentan en la documentación de entrega.

---

## 1. Estructura de Evidencias

```text
E4 - VPN y DMZ/evidencias/
├── README.md                      # Este índice
├── logs/                          # Salida de consola y capturas de tráfico en texto (17 archivos)
│   ├── E1-pcmgmt01-hacia-web01-bloqueado-20261004.log
│   ├── E3-tcpdump-wlp3s0-udp51820-20261005.log
│   ├── E4-adaptador-wifi-segunda-red-20261009.log
│   ├── E4-dns-filtro-operador-20261004-20261009.log
│   ├── E4-failover-ip-salida.log
│   ├── E4-matriz-admin1.log
│   ├── E4-matriz-dmz.log
│   ├── E4-matriz-user1.log
│   ├── E4-ngrok-crl-antes-despues-20261004.log
│   ├── E4-setup-perfiles-wg0-20261010.log
│   ├── E4-vpn-telefono-udp51820-enp1s0-20261005.log
│   ├── E4-vpn-telefono-wg0-admin1-20261005.log
│   ├── E4-vpn-telefono-wg0-user1-20261005.log
│   ├── E4-vpn-user1-bloqueo-admin-enp1s0-20261005.log
│   ├── E4-web01-desde-lan-apache-20261004.log
│   ├── E4-web01-desde-lan-tcpdump-8081-20261004.log
│   └── E5-deny-vpnusers2admin-20261005.log
└── capturas/                      # Capturas de pantalla (7 archivos)
    ├── captura-01-wg-show-handshake-telefono.png
    ├── captura-02-wg-show-peers-registrados.png
    ├── captura-03-telefono-wireguard-perfiles.jpg
    ├── captura-04-telefono-vpn-web01.jpg
    ├── captura-05-telefono-vpn-srv-intra01.jpg
    ├── captura-06-cliente-lan-web01.png
    └── captura-07-ngrok-sesion-online.png
```

Los logs conservan la salida original. Cada uno empieza con un encabezado de líneas `#` que dice quién la generó, cuándo, con qué comando y qué muestra; en los que el terminal traía el prompt decorativo, este se reemplazó por `[hora] $ comando`. Los logs de `E1-`, `E3-` y `E5-` son salidas que esos componentes enviaron al chat del equipo.

---

## 2. Inventario de Evidencias

### 2.1 Matriz de pruebas (`test/vpn_matrix.sh`)

Se ejecutó el 2026-10-10 desde el equipo E4, con el cliente WireGuard dentro de un *network namespace* (`scripts/vpn_client_ns.sh`) y el resto de la red real: E5 (firewall), R1 (ACL de la LAN) y E3. Cada línea indica quién decide el resultado: **E4** (WireGuard), **E5** (firewall perimetral) o **R1** (ACL de la LAN). Los logs son la salida original: el script se tradujo al español con tildes después de ejecutarlas, pero los casos y los resultados son los mismos.

| Archivo | Comando | Resultado | Qué demuestra |
|---|---|:---:|---|
| [`logs/E4-matriz-admin1.log`](./logs/E4-matriz-admin1.log) | `sudo ./test/vpn_matrix.sh admin1` | **12 PASS / 0 FAIL** | Handshake, Full Tunnel y DNS por el túnel (I1–I4); acceso a WEB01 (I5) y a Internet (I6); VPN-ADMIN llega a las VLAN ADMIN y USERS, a Zabbix, a la Intranet y a GESTIÓN (A1–A5); la web de Zabbix queda restringida a la VLAN ADMIN por R1 (A6) |
| [`logs/E4-matriz-user1.log`](./logs/E4-matriz-user1.log) | `sudo ./test/vpn_matrix.sh user1` | **16 PASS / 0 FAIL** | VPN-USERS llega solo a la VLAN USERS y a la Intranet por 80 y 443 (U1–U3); se bloquean el SSH y el ping a la Intranet, la VLAN ADMIN, GESTIÓN y la web de Zabbix (U4–U8); un `user1` que usa la IP de un administrador es descartado por WireGuard (S1–S2) |
| [`logs/E4-matriz-dmz.log`](./logs/E4-matriz-dmz.log) | `sudo ./test/vpn_matrix.sh dmz` | **9 PASS / 0 FAIL** | WEB01 responde en la DMZ (D1); la DMZ no inicia conexiones hacia la LAN ni a Zabbix (D2–D4, D9); solo sale por HTTPS (D5, D6); el host E4 sí puede usar el puerto 80 para la CRL de ngrok y el 10051 de Zabbix (D7, D8) |

### 2.2 Flujo B — VPN con un teléfono real (2026-10-05)

Un teléfono con la app de WireGuard, conectado a la WiFi del ISP1 (`192.168.1.6`), entra por E3 y E5 hasta E4 con el perfil `admin1` y luego con `user1`. Las capturas están tomadas en los tres equipos del camino.

| Archivo | Equipo | Qué demuestra |
|---|:---:|---|
| [`logs/E3-tcpdump-wlp3s0-udp51820-20261005.log`](./logs/E3-tcpdump-wlp3s0-udp51820-20261005.log) | E3 | 575 paquetes UDP/51820 de `192.168.1.6:59934` a `192.168.1.10` (WAN1 de E3) entre las 00:59:13 y las 00:59:59; el primero, de 148 bytes, es el inicio del *handshake*. Solo aparece el sentido de entrada |
| [`logs/E4-vpn-telefono-udp51820-enp1s0-20261005.log`](./logs/E4-vpn-telefono-udp51820-enp1s0-20261005.log) | E4 | Primera pasada vista en E4 tras E3 (DNAT) y E5: 172 paquetes entre `192.168.1.6` y `192.168.83.2:51820` (91 de entrada y 81 de respuesta). La IP de origen del teléfono se conserva hasta E4 |
| [`logs/E4-vpn-telefono-wg0-admin1-20261005.log`](./logs/E4-vpn-telefono-wg0-admin1-20261005.log) | E4 | Segunda pasada: 227 paquetes ya descifrados de `admin1` (`10.200.10.10`) hacia WEB01 (`172.16.10.10:8081`), la Intranet (`192.168.30.20:80`) e Internet |
| [`logs/E4-vpn-telefono-wg0-user1-20261005.log`](./logs/E4-vpn-telefono-wg0-user1-20261005.log) | E4 | 237 paquetes de `user1` (`10.200.20.10`, VPN-USERS) hacia Internet por el túnel (Full Tunnel), más sus intentos hacia `192.168.10.50` |
| [`logs/E4-vpn-user1-bloqueo-admin-enp1s0-20261005.log`](./logs/E4-vpn-user1-bloqueo-admin-enp1s0-20261005.log) | E4 | 67 SYN de `user1` hacia PC-ADMIN01 (`192.168.10.50:80`) salen de E4 hacia E5 y no reciben respuesta; en cambio, a la 01:25:04, dos paquetes `RST` de `192.168.10.50` van dirigidos a `10.200.10.10` (`admin1`): con el perfil de administrador el paquete sí llega al equipo y este responde |
| [`logs/E5-deny-vpnusers2admin-20261005.log`](./logs/E5-deny-vpnusers2admin-20261005.log) | E5 | 36 registros `[E5-DENY-VPNUSERS2ADMIN]` entre las 01:23:26 y las 01:29:25: E5 descarta los SYN de `10.200.20.10` hacia `192.168.10.50:80` que entran por el enlace de E4 y salían por el de E2. Son 5 intentos de conexión (puertos de origen 51447, 51448, 51462, 51473 y 51487); el primero coincide con el primer paquete de la captura de E4 (01:23:26, puerto 51447) |

### 2.3 Flujo LAN → DMZ (2026-10-04)

| Archivo | Equipo | Qué demuestra |
|---|:---:|---|
| [`logs/E4-web01-desde-lan-tcpdump-8081-20261004.log`](./logs/E4-web01-desde-lan-tcpdump-8081-20261004.log) | E4 | 144 paquetes entre las 23:15:04 y las 23:25:03: PC-ADMIN01 (`192.168.10.50`), PC-USER01 (`192.168.20.10`) y Zabbix (`192.168.30.10`) completan el *handshake* TCP con WEB01 (`172.16.10.10:8081`) y reciben respuesta; R1 (`192.168.10.1`) abre y cierra conexiones de inmediato. La IP de origen es la real, sin NAT |
| [`logs/E4-web01-desde-lan-apache-20261004.log`](./logs/E4-web01-desde-lan-apache-20261004.log) | E4 | Registro de Apache de WEB01: peticiones `GET /` con código 200 desde `192.168.10.50`, `192.168.20.10` y `192.168.30.10` |
| [`logs/E1-pcmgmt01-hacia-web01-bloqueado-20261004.log`](./logs/E1-pcmgmt01-hacia-web01-bloqueado-20261004.log) | E1 | PC-MGMT01 (VLAN de GESTIÓN) no alcanza WEB01: código `000` y tiempo de espera agotado, como exige la política |

### 2.4 Flujo C — ngrok (2026-10-04)

| Archivo | Qué demuestra |
|---|---|
| [`logs/E4-ngrok-crl-antes-despues-20261004.log`](./logs/E4-ngrok-crl-antes-despues-20261004.log) | El problema de la lista de revocación (CRL) de ngrok y su solución. Antes: el agente queda en `reconnecting (... timed out fetching CRL)` y la descarga por HTTP/80 expira. Después de que E5 permitió TCP/80 solo desde `192.168.83.2`: la CRL responde `200 OK` y la URL pública responde `http=200` |
| [`capturas/captura-07-ngrok-sesion-online.png`](./capturas/captura-07-ngrok-sesion-online.png) | La sesión de ngrok en línea (ver sección 2.7) |

### 2.5 Salida a Internet con el Multi-WAN (2026-10-10)

| Archivo | Qué demuestra |
|---|---|
| [`logs/E4-failover-ip-salida.log`](./logs/E4-failover-ip-salida.log) | IP pública de salida del equipo E4 (`curl https://1.1.1.1/cdn-cgi/trace`) según el ISP activo: con ISP1 activo sale por `190.143.186.95` y con solo ISP2, por `181.174.73.105`. La salida cambia de ISP cuando ISP1 deja de estar disponible |

### 2.6 Configuración aplicada, segunda red WiFi y DNS

| Archivo | Qué demuestra |
|---|---|
| [`logs/E4-setup-perfiles-wg0-20261010.log`](./logs/E4-setup-perfiles-wg0-20261010.log) | 2026-10-10: `setup_e4.sh --apply` (enlace a E5, ruta por defecto, `dmz0` con `172.16.10.1` y `172.16.10.10`), perfiles `-isp2` con `gen_peers.sh --suffix isp2`, `wg0` arriba con `10.200.10.1` y `10.200.20.1`, y `setup_e4.sh --status` con 0 fallos |
| [`logs/E4-adaptador-wifi-segunda-red-20261009.log`](./logs/E4-adaptador-wifi-segunda-red-20261009.log) | 2026-10-09: un adaptador USB WiFi como segunda red. Un teléfono en su hotspot (`10.181.227.66`) completa el *handshake* con `wg0` (paquetes de 148 y 92 bytes a las 23:47:05, `wg show` con `latest handshake`) y hace ping al servidor: 8 de 8 con el túnel activo y 0 de 6 con el túnel inactivo. Es una prueba de E4 sola, sin pasar por E3 ni E5 |
| [`logs/E4-dns-filtro-operador-20261004-20261009.log`](./logs/E4-dns-filtro-operador-20261004-20261009.log) | `8.8.8.8` responde 20/20 siempre; `1.1.1.1`, `9.9.9.9` y `8.8.4.4` pierden consultas UDP/53 por la red del proyecto, y `1.1.1.1` no responde ninguna (0/20) en el hotspot del operador móvil, sin pasar por E3 ni E5. Por TCP/53 todos responden. Es la razón de que `8.8.8.8` vaya primero en los perfiles y en `config/resolv-ngrok.conf` |

### 2.7 Capturas de pantalla

| # | Imagen | Qué demuestra |
|---|---|---|
| 01 | [`captura-01-wg-show-handshake-telefono.png`](./capturas/captura-01-wg-show-handshake-telefono.png) | `watch -n2 'sudo wg show wg0'` el 2026-10-11 a las 01:07: `admin1` (`10.200.10.10/32`) y `user1` (`10.200.20.10/32`) con *handshake* reciente (28 s y 1 min 23 s) y tráfico cifrado en ambos sentidos, desde el endpoint `192.168.1.35` del teléfono. Es la primera pasada del flujo B: teléfono → E3 → E5 → E4 |
| 02 | [`captura-02-wg-show-peers-registrados.png`](./capturas/captura-02-wg-show-peers-registrados.png) | Los cinco peers registrados en `wg0` con su llave pública y su `AllowedIPs` individual (`10.200.10.10`, `.11` para VPN-ADMIN; `10.200.20.10`, `.11`, `.12` para VPN-USERS), puerto de escucha `51820` y llave privada oculta. `admin1` aparece con el teléfono como endpoint y `user1` con `10.99.0.2`, el cliente de pruebas del *namespace* |
| 03 | [`captura-03-telefono-wireguard-perfiles.jpg`](./capturas/captura-03-telefono-wireguard-perfiles.jpg) | App de WireGuard del teléfono con los cuatro túneles importados, todos apagados: `admin1` y `user1` (entrada por ISP1) y `admin1-isp2` y `user1-isp2` (entrada por ISP2). Un perfil tiene un solo `Endpoint`, por eso hay un perfil por cada vía de entrada |
| 04 | [`captura-04-telefono-vpn-web01.jpg`](./capturas/captura-04-telefono-vpn-web01.jpg) | WEB01 abierto desde el teléfono en `http://172.16.10.10:8081` con la VPN activa (el icono de llave de la barra de estado). Es una dirección privada de la DMZ: solo se alcanza a través del túnel |
| 05 | [`captura-05-telefono-vpn-srv-intra01.jpg`](./capturas/captura-05-telefono-vpn-srv-intra01.jpg) | SRV-INTRA01 (`192.168.30.20`, VLAN 30) abierto desde el teléfono con la VPN activa: el cliente remoto llega a la LAN a través de E3, E5, E4, y de nuevo E5, E2 y E1 (flujo B, doble pasada) |
| 06 | [`captura-06-cliente-lan-web01.png`](./capturas/captura-06-cliente-lan-web01.png) | WEB01 abierto en `http://172.16.10.10:8081` desde un equipo de la LAN de E1 (el 2026-10-10 a las 20:25). Es el flujo LAN → DMZ, a través de R1, E2 y E5 |
| 07 | [`captura-07-ngrok-sesion-online.png`](./capturas/captura-07-ngrok-sesion-online.png) | Servicio ngrok levantado con `scripts/run_ngrok.sh`: `Session Status: online`, `Forwarding https://bennett-smartish-waterlessly.ngrok-free.dev -> http://localhost:8081` y una petición `GET /` con `200 OK`. Es el flujo C: la publicación de WEB01 sin IP pública ni puertos entrantes |

---

## 3. Evidencias de otros componentes relacionadas con E4

| Qué | Dónde |
|---|---|
| Enlace E4–E5 (`192.168.83.0/30`): ARP, ICMP y alertas del IDS | [`E5 - Firewall/evidencias/pcap/E5-T03-e4-e5-connectivity.pcap`](../../E5%20-%20Firewall/evidencias/pcap/E5-T03-e4-e5-connectivity.pcap) y el log `E5-T03-e4-e5.log` |
| Flujo C: transporte TLS entre E4 (`192.168.83.2`) y ngrok por E5 | [`E5 - Firewall/evidencias/pcap/E5-T12-flujo-c-dmz-ngrok.pcap`](../../E5%20-%20Firewall/evidencias/pcap/E5-T12-flujo-c-dmz-ngrok.pcap) |
| Políticas de acceso de la VPN y de la DMZ (reglas y matriz de seguridad) | [`E5 - Firewall/config/e5-firewall.nft`](../../E5%20-%20Firewall/config/e5-firewall.nft) y [`tablas/matriz-seguridad.csv`](../../tablas/matriz-seguridad.csv) |


