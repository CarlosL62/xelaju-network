# Estudiante 5 — Firewall Perimetral (nftables) + IDS (Suricata)

**Responsable:** Estudiante 5<br>
**Curso:** Redes de Computadoras 2 — CUNOC / USAC<br>
**Sistema:** Debian GNU/Linux (Modo Consola / Texto)<br>
**Rol en la infraestructura:** Núcleo de seguridad perimetral con filtrado de paquetes con estado (*stateful firewall*), control de acceso entre zonas perimetrales e inspección profunda de intrusiones en tiempo real (*IDS*).

---

## 1. Objetivo y Responsabilidad del Componente

El nodo **E5** tiene a su cargo la seguridad en el perímetro de la red corporativa de XelajuNetwork. Sus funciones principales son:

- **Filtrado Perimetral con Estado (*nftables*):** Implementar una política estricta de denegación por defecto (`policy drop`) en las cadenas de entrada (`input`) y reenvío (`forward`), permitiendo únicamente los flujos explícitamente autorizados por los contratos de red y manteniendo el seguimiento de conexiones con *conntrack*.
- **Demarcación de Seguridad:** Controlar el tráfico que cruza entre el exterior (Internet vía E3), la red interna (vía el proxy E2 y router LAN E1) y los servicios perimetrales (WireGuard VPN y DMZ en E4). No duplica las ACL internas inter-VLAN de E1.
- **Doble Pasada de VPN (WireGuard):** Inspeccionar el tráfico VPN en dos fases diferenciadas: primero autorizar el túnel cifrado hacia E4 (UDP 51820) y luego filtrar el tráfico descifrado devuelto por E4 aplicando políticas diferenciadas para `VPN-ADMIN` y `VPN-USERS`.
- **Inspección Profunda de Intrusiones (*Suricata 7.0.10*):** Monitorear de forma pasiva en tiempo real las tres interfaces físicas perimetrales mediante captura de alto rendimiento `af-packet`, aplicando reglas comunitarias Emerging Threats (ET Open) y firmas locales personalizadas.

---

## 2. Entorno Debian y Dependencias

- **Sistema Operativo:** Debian GNU/Linux 13 (trixie) ejecutado en modo texto / terminal.
- **Paquetes y Herramientas del Sistema:**
  - `nftables`: Motor de filtrado de paquetes del kernel.
  - `suricata` (versión 7.0.10): Motor de detección de intrusiones (IDS).
  - `tshark` / `tcpdump`: Captura y análisis forense de paquetes.
  - `iproute2`: Gestión de interfaces y tablas de enrutamiento del kernel (`ip link`, `ip addr`, `ip route`).
  - `sysctl`: Habilitación persistente de reenvío IPv4 (`net.ipv4.ip_forward = 1`).

---

## 3. Interfaces Físicas y Enlaces

El host físico de E5 interconecta tres enlaces punto a punto `/30` delimitados físicamente con sus pares en la topología:

| Interfaz Hardware | Rol Canónico | Peer Conectado | IP E5 | IP Peer | Estado Enlace |
|---|---|---|:---:|:---:|:---:|
| `eno2` | `perimeter_external` | **E3** (Multi-WAN) | `192.168.81.2/30` | `192.168.81.1` | `UP` / Operativo |
| `enxc0eac367f731` | `internal_lan_facing` | **E2** (Squid / LAN) | `192.168.82.1/30` | `192.168.82.2` | `UP` / Enlace físico activo |
| `enxf8e43ba69459` | `dmz_facing` | **E4** (VPN / DMZ) | `192.168.83.1/30` | `192.168.83.2` | `UP` / Operativo |
| `wlo1` | *Administración local* | Red Wi-Fi laboratorio | `192.168.1.176/24` | `192.168.1.1` | Acceso SSH administrativo |

> [!NOTE]
> La interfaz `wlo1` se utiliza exclusivamente para acceso administrativo SSH fuera de la topología del proyecto. Todo el tráfico operativo de XelajuNetwork utiliza la ruta por defecto hacia E3 (`192.168.81.1 dev eno2`).

---

## 4. Direccionamiento y Rutas del Kernel

Definidas de forma persistente en `/etc/network/interfaces` (ver plantilla [`config/interfaces.example`](./config/interfaces.example)):

| Red Destino | Máscara | Próximo Salto (*Next-Hop*) | Interfaz | Zona / Propósito |
|---|---|:---:|:---:|---|
| `0.0.0.0/0` | `0.0.0.0` | `192.168.81.1` | `eno2` | Salida predeterminada hacia Internet (E3) |
| `192.168.10.0/24` | `255.255.255.0` | `192.168.82.2` | `enxc0eac367f731` | VLAN 10 (ADMIN) vía E2 |
| `192.168.20.0/24` | `255.255.255.0` | `192.168.82.2` | `enxc0eac367f731` | VLAN 20 (USERS) vía E2 |
| `192.168.30.0/24` | `255.255.255.0` | `192.168.82.2` | `enxc0eac367f731` | VLAN 30 (SERVERS / Zabbix) vía E2 |
| `192.168.40.0/24` | `255.255.255.0` | `192.168.82.2` | `enxc0eac367f731` | VLAN 40 (MGMT) vía E2 |
| `192.168.84.0/30` | `255.255.255.252` | `192.168.82.2` | `enxc0eac367f731` | Tránsito E1 ↔ E2 vía E2 |
| `10.200.10.0/24` | `255.255.255.0` | `192.168.83.2` | `enxf8e43ba69459` | Clientes remotos VPN-ADMIN vía E4 |
| `10.200.20.0/24` | `255.255.255.0` | `192.168.83.2` | `enxf8e43ba69459` | Clientes remotos VPN-USERS vía E4 |
| `172.16.10.0/24` | `255.255.255.0` | `192.168.83.2` | `enxf8e43ba69459` | DMZ (Servidor WEB01) vía E4 |

---

## 5. Firewall nftables: Default-Deny, Conntrack y Políticas Interzonas

El firewall se estructura bajo la tabla `inet xelaju_e5` (archivo [`config/e5-firewall.nft`](./config/e5-firewall.nft)):

### A. Política por Defecto y Manejo de Estado
- Cadenas `input` y `forward` con `policy drop`.
- Primera regla obligatoria: `ct state established,related accept` para permitir el retorno automático de sesiones legítimas.
- Descarte de tráfico malformado: `ct state invalid drop`.

### B. Políticas Interzonas Implementadas
1. **Flujo A (Navegación Web Saliente y Tráfico LAN):**
   - Tráfico originado por el proxy Squid (`192.168.82.2`) permitido hacia Internet (TCP 80, DNS UDP/TCP 53).
   - Tráfico directo de clientes LAN permitido hacia Internet para HTTPS (TCP 443), DNS (UDP/TCP 53) y NTP (UDP 123).
2. **Flujo B (WireGuard Doble Pasada):**
   - **Pasada 1 (Cifrada):** Internet -> E3 -> E5 -> E4: permitido `udp dport 51820` hacia `192.168.83.2`.
   - **Pasada 2 (Descifrada):** Tráfico procedente de E4 (`enxf8e43ba69459`) ingresando hacia LAN (`enxc0eac367f731`):
     - `VPN-ADMIN` (`10.200.10.0/24`): Acceso total autorizado a las VLANs 10, 20, 30 y 40 con log representativo.
     - `VPN-USERS` (`10.200.20.0/24`): Acceso permitido a VLAN 20 (Usuarios) y acceso web restringido a `192.168.30.20` (SRV-INTRA01 en puertos TCP 80/443). Bloqueo explícito con log hacia VLAN 10 (ADMIN).
     - Salida a Internet VPN (Full Tunnel): Tráfico saliente de `10.200.10.0/24` y `10.200.20.0/24` hacia E3 permitido.
3. **Flujo C (Publicación DMZ y ngrok):**
   - Túnel ngrok saliente: Tráfico desde E4 / DMZ permitido hacia Internet en TCP 443 y DNS UDP/TCP 53.
   - Dependencia CRL de ngrok: Excepción HTTP (TCP 80) autorizada hacia Internet para validación de certificados por el host E4.
   - Acceso interno a DMZ: Clientes LAN autorizados hacia WEB01 (`172.16.10.10:8081`).
   - Aislamiento perimetral: Todo tráfico directo no solicitado desde Internet hacia DMZ o LAN es descartado y registrado con prefijo de log.
4. **Monitoreo Zabbix:**
   - Tráfico de agentes activos desde E3 (`192.168.81.1`) y E4 (`192.168.83.2`) hacia el servidor Zabbix en E1 (`192.168.30.10:10051`) permitido para recolección de métricas.

---

## 6. Configuración y Funcionamiento de Suricata IDS

- **Motor Seleccionado:** Suricata 7.0.10 en modo pasivo multi-interfaz.
- **Mecanismo de Captura:** `af-packet` escuchando concurrentemente sobre las interfaces perimetrales:
  - `eno2` (Cluster ID 99)
  - `enxc0eac367f731` (Cluster ID 98)
  - `enxf8e43ba69459` (Cluster ID 97)
- **Definición de Redes:**
  - `HOME_NET`: Incluye todas las subredes corporativas internas, enlaces `/30`, VPN y DMZ.
  - `EXTERNAL_NET`: Negación estricta de `$HOME_NET` (`!$HOME_NET`).
- **Reglas y Firmas:**
  - Reglas comunitarias ET Open activas.
  - Firma local de verificación [`config/local.rules`](./config/local.rules):
    ```suricata
    alert icmp any any -> any any (msg:"ICMP Echo Request detectado"; itype:8; sid:1000001; rev:1;)
    ```
- **Registro de Eventos:** Alertas en `/var/log/suricata/fast.log` y eventos estructurados en `/var/log/suricata/eve.json`.

---

## 7. Scripts y Comandos de Administración

Los scripts funcionales de E5 están ubicados en [`scripts/`](./scripts/) (instalables en `/usr/local/sbin/`):

| Comando | Sintaxis | Descripción |
|---|---|---|
| `e5-status` | `sudo e5-status` | Panel integral con estado de hardware, interfaces, rutas, forwarding, nftables y Suricata. |
| `e5-firewall` | `sudo e5-firewall {status\|check\|show\|backup\|apply}` | Verificación de sintaxis, respaldo y recarga segura de reglas nftables. |
| `e5-ids` | `sudo e5-ids {status\|check\|rules\|alerts\|restart}` | Control del servicio Suricata, validación de reglas y visualización de alertas en tiempo real. |
| `e5-capture` | `sudo e5-capture {live\|save\|list} [interfaz] [segundos]` | Captura de paquetes perimetrales en vivo o almacenamiento en formato PCAP rotado. |
| `e5-help` | `e5-help` | Manual rápido interactivo con la referencia de puertos, enlaces y sintaxis. |
| `setup_ids.sh` | `sudo ./scripts/provisioning/setup_ids.sh` | Aprovisionamiento automatizado de `HOME_NET`, `af-packet` y `local.rules` en Suricata. |

---

## 8. Procedimientos de Comprobación

1. **Validación Sintáctica de Reglas:**
   ```bash
   sudo nft -c -f config/e5-firewall.nft
   ```
2. **Validación de Configuración de Suricata:**
   ```bash
   sudo suricata -T -c config/suricata.yaml.example
   ```
3. **Prueba de Reenvío y Estado del Kernel:**
   ```bash
   sysctl net.ipv4.ip_forward
   ip route show
   ```
4. **Verificación de Alertas en Tiempo Real:**
   ```bash
   sudo tail -f /var/log/suricata/fast.log
   ```

---

## 9. Resultados Realmente Verificados

- **Persistencia en Reinicio:** Configuración de interfaces fijas, rutas estáticas, forwarding en kernel (`sysctl`), servicio `nftables` y servicio `suricata` verificados y persistentes tras reinicio físico del host Debian.
- **Conectividad e Inspección E2 ↔ E5:** Enlace L2/L3 verificado en sesión del 11/10/2026 con resolución ARP mutua, 8 paquetes ICMP (0% pérdida) y 8 alertas en Suricata `SID 1000001` sobre `enxc0eac367f731`. Este resultado corresponde a dicha sesión empírica.
- **Tránsito Perimetral E4 ↔ Internet:** Tránsito verificado retornando respuestas HTTP 301 con simetría hacia Internet a través de E5 y E3.
- **Túnel ngrok Operativo:** Establecimiento exitoso del túnel ngrok desde E4 a través de E5 tras la habilitación de la regla de excepción CRL (TCP 80).
- **Detección en Motor IDS:** Detección de paquetes ICMP verificada en motor Suricata con registro de alerta `SID 1000001` en `/var/log/suricata/fast.log` para las interfaces perimetrales.

---

## 10. Evidencias Disponibles y Pendientes

- **Disponibles:**
  - Lote oficial de evidencias técnicas en [`evidencias/`](./evidencias/) (6 registros de log formateados y 7 capturas PCAP auténticas, verificados con SHA-256).
  - Registros de alertas en `/var/log/suricata/fast.log` (muestra representativa en [`evidencias/logs/suricata-alert-sample.log`](./evidencias/logs/suricata-alert-sample.log)).
  - Capturas perimetrales PCAP almacenadas localmente en `/var/log/xelaju-e5/captures/`.
- **Pendientes:**
  - **Prueba integral simultánea:** Ejecución concurrente de los flujos A, B y C con todos los 5 nodos interconectados y encendidos simultáneamente en el laboratorio.
  - **Capturas visuales:** Capturas de pantalla gráficas de Wireshark GUI y terminales de alertas a partir de los PCAP para el informe académico impreso.
