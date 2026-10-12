# Estudiante 4 — WireGuard VPN y Zona Desmilitarizada (DMZ)

**Responsable:** Estudiante 4<br>
**Curso:** Redes de Computadoras 2 — CUNOC / USAC<br>
**Sistema:** Debian GNU/Linux (Modo Consola / Texto)<br>
**Rol en la infraestructura:** Servidor de acceso remoto seguro mediante WireGuard VPN con subredes diferenciadas, alojamiento de servicios DMZ (WEB01) y publicación externa mediante túnel seguro ngrok.

---

## 1. Descripción y Responsabilidad del Componente

El componente **E4** concentra la terminación de accesos remotos y los servicios públicos perimetrales de XelajuNetwork. Sus responsabilidades son:
- Implementación de un servidor VPN WireGuard en Debian con asignación de rangos IP diferenciados para usuarios administrativos (`VPN-ADMIN: 10.200.10.0/24`) y usuarios comunes (`VPN-USERS: 10.200.20.0/24`).
- Conexión física exclusiva hacia el firewall perimetral E5 a través del enlace `192.168.83.0/30`, asegurando que todo el tráfico pase por el firewall perimetral antes y después de su procesamiento (modelo de doble pasada).
- Alojamiento y mantenimiento de la zona desmilitarizada (DMZ) en la subred `172.16.10.0/24`, donde opera el servidor web perimetral WEB01 (`172.16.10.10`).
- Publicación hacia Internet de al menos un servicio DMZ a través de un túnel ngrok originado hacia el exterior desde el entorno interno, sin requerir una dirección IPv4 pública directa en el servidor.

---

## 2. Requisitos del Enunciado Oficial

- **Servidor WireGuard:** Servicio VPN activo en Debian en el puerto UDP 51820.
- **Diferenciación de Clientes VPN:** Asignación estricta de subredes para permitir que E5 aplique reglas de acceso diferenciadas hacia la LAN corporativa.
- **Servicios DMZ:** Configuración de servidor web perimetral en la subred DMZ accesible desde clientes autorizados.
- **Túnel ngrok:** Publicación segura del servicio web con URL pública accesible para usuarios externos.

---

## 3. Configuraciones

Ninguna carpeta del repositorio contiene llaves privadas ni el *authtoken* de ngrok: lo que se versiona son plantillas con marcadores `<...>` y los valores públicos. Los secretos viven solo en el equipo E4 (`/etc/wireguard/wg0.conf`, configuración local de ngrok) y en cada cliente.

| Archivo | Qué configura | Dónde se aplica en el equipo E4 |
|---|---|---|
| [`config/e4.env`](./config/e4.env) | Parámetros de direccionamiento de E4: enlace a E5 (`192.168.83.2/30`, puerta de enlace `192.168.83.1`), DMZ (`172.16.10.1/24` y WEB01 `172.16.10.10/24` en la interfaz dummy `dmz0`), direcciones de `wg0`, los cinco peers de prueba, Full Tunnel y DNS de los perfiles | Lo leen todos los scripts |
| [`config/wireguard/server.conf.example`](./config/wireguard/server.conf.example) | Interfaz `wg0` del servidor (`10.200.10.1/24` y `10.200.20.1/24`, UDP/51820) y un bloque `[Peer]` por cada cliente con su `/32` | `/etc/wireguard/wg0.conf` (modo 600; la llave privada se coloca solo en el equipo) |
| [`config/wireguard/client.conf.example`](./config/wireguard/client.conf.example) | Perfil de cliente: Full Tunnel (`AllowedIPs = 0.0.0.0/0, ::/0`), `DNS = 8.8.8.8`, `PersistentKeepalive = 25` | Lo genera `scripts/gen_peers.sh` para cada peer, fuera del repositorio |
| [`config/resolv-ngrok.conf`](./config/resolv-ngrok.conf) | Resolvedores DNS del proyecto (`8.8.8.8` primero) para ngrok y las pruebas, dentro de un espacio de montajes privado | Lo usan `scripts/run_ngrok.sh` y `scripts/with_dns.sh`; el `/etc/resolv.conf` real no se modifica |
| [`dmz/web01-dmz.conf`](./dmz/web01-dmz.conf) | Host virtual de Apache de WEB01 en el puerto `8081` | `/etc/apache2/sites-available/web01-dmz.conf`, habilitado con `a2ensite` |
| [`dmz/index.html`](./dmz/index.html), [`dmz/favicon.ico`](./dmz/favicon.ico) | Contenido de WEB01: página autocontenida (sin fuentes ni scripts externos) | `/var/www/web01-dmz/` |

**Interfaces hacia E5 y de la DMZ.** No son archivos: las crea [`scripts/setup_e4.sh`](./scripts/setup_e4.sh) a partir de `config/e4.env` (sección 4).

**Servidor web de la DMZ (Apache, puerto 8081).**

```bash
sudo mkdir -p /var/www/web01-dmz
sudo cp dmz/web01-dmz.conf /etc/apache2/sites-available/web01-dmz.conf
sudo cp dmz/index.html dmz/favicon.ico /var/www/web01-dmz/
sudo a2ensite web01-dmz && sudo systemctl reload apache2
```

**Túnel ngrok.** El agente se autentica una sola vez con `ngrok config add-authtoken <TOKEN>` (el token queda en la configuración local de ngrok, no en este repositorio) y el túnel se levanta con `scripts/run_ngrok.sh`, que ejecuta `ngrok http 8081` con los resolvedores de `config/resolv-ngrok.conf`.

---

## 4. Scripts

Todos los scripts son de bash y están documentados con `--help`. `setup_e4.sh` y `gen_peers.sh` son una simulación (*dry-run*) salvo que se pase `--apply`; `vpn_client_ns.sh up` admite `--dry-run`.

| Script | Función |
|---|---|
| [`scripts/setup_e4.sh`](./scripts/setup_e4.sh) | Aplica la parte de E4 del plan de direccionamiento: reenvío de IP persistente, `192.168.83.2/30` en el enlace a E5, ruta por defecto vía `192.168.83.1`, interfaz `dmz0` con `172.16.10.1/24` y `172.16.10.10/24`, y verifica `wg0`. Opciones `--status` (comprobaciones PASS/FAIL) y `--teardown`. Idempotente; no cambia una ruta por defecto existente sin `--force-default` |
| [`scripts/gen_peers.sh`](./scripts/gen_peers.sh) | Alta y gestión de claves y clientes remotos: genera las llaves y los perfiles de los cinco peers (fuera del repositorio), los instala en `wg0.conf` con copia de respaldo y sincroniza `wg0` sin reiniciarlo, y muestra el QR de un perfil en la terminal para importarlo en el teléfono. `--suffix isp2` crea un segundo perfil con las mismas llaves y otro *endpoint* |
| [`scripts/run_ngrok.sh`](./scripts/run_ngrok.sh) | Inicia el túnel ngrok hacia WEB01 con DNS propio; `--check` verifica cómo resuelve `connect.ngrok-agent.com` |
| [`scripts/with_dns.sh`](./scripts/with_dns.sh) | Ejecuta cualquier comando, o una shell, con los resolvedores del proyecto, sin root y sin tocar el DNS del sistema |
| [`scripts/vpn_client_ns.sh`](./scripts/vpn_client_ns.sh) | Cliente WireGuard dentro de un *network namespace* del mismo equipo: permite probar las políticas de VPN-ADMIN y VPN-USERS con `ping`, `nc` y `curl` sin teléfono. Cubre la segunda pasada del flujo B |
| [`test/vpn_matrix.sh`](./test/vpn_matrix.sh) | Matriz de pruebas con resultado PASS/FAIL: casos de VPN-ADMIN, VPN-USERS (incluida la prueba anti-suplantación) y aislamiento de la DMZ. Guarda el resultado fuera del repositorio |

Orden de puesta en marcha en el equipo E4 (`/etc/wireguard/wg0.conf` debe existir antes con la sección `[Interface]` y la llave privada del servidor, según `config/wireguard/server.conf.example`):

```bash
sudo ./scripts/setup_e4.sh --uplink enp1s0 --apply                  # enlace a E5, DMZ y reenvío de IP
./scripts/gen_peers.sh --endpoint <IP_WAN_DE_E3>:51820 --apply      # llaves y perfiles de los clientes
sudo ./scripts/gen_peers.sh --install-server --apply                # peers en /etc/wireguard/wg0.conf
sudo wg-quick up wg0                                                # servidor WireGuard
./scripts/run_ngrok.sh 8081                                         # publicación de WEB01
sudo ./test/vpn_matrix.sh dmz                                       # pruebas (también: admin1, user1)
```

Las llaves y perfiles se guardan en `~/.local/share/xelaju-e4/wireguard` y los resultados de las pruebas en `~/.local/share/xelaju-e4/results`, ambos fuera del repositorio.

---

## 5. Funcionamiento

- **Flujo B (Acceso Remoto VPN):** Clientes remotos se conectan por WireGuard cruzando E5 hacia E4. E4 descifra los paquetes y los reenvía por su ruta por defecto de vuelta a E5 (`192.168.83.1`), donde el firewall aplica las políticas de acceso hacia LAN.
- **Flujo C (Publicación DMZ):** El servicio web WEB01 corre localmente en la DMZ. El agente ngrok establece una conexión saliente TLS hacia los servidores de ngrok, permitiendo el ingreso de usuarios externos sin abrir puertos directos en el router.

---

## 6. Evidencias y Pruebas

Las evidencias (logs de la matriz de pruebas y capturas de WireGuard, WEB01, la Intranet y ngrok) y su inventario están en [`evidencias/`](./evidencias/README.md).

- Comprobación de handshake y transferencia de datos en WireGuard.
- Comprobación de acceso de cliente VPN-ADMIN a la LAN y restricción de VPN-USERS.
- Acceso exitoso a la URL pública de ngrok desde navegadores externos.
