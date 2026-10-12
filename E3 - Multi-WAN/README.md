# Estudiante 3 — Enrutamiento Multi-WAN, Balanceo, Tolerancia a Fallos, NAT y Zabbix

**Responsable:** Estudiante 3 (E3)  
**Curso:** Redes de Computadoras 2 — CUNOC / USAC  
**Entorno Operativo:** Debian GNU/Linux (Modo Consola / Texto)  
**Rol en la Infraestructura:** Router de Borde (*Edge Router*) perimetral, doble conexión concurrente hacia proveedores de Internet (Multi-WAN), enrutamiento basado en políticas (*Policy-Based Routing / PBR*), balanceo de carga con persistencia de estado (*connection tracking*), tolerancia a fallos y conmutación automática (*failover / failback*), traducción de direcciones (*DNAT WireGuard* y *SNAT/Masquerade* perimetral centralizado) y exportación de telemetría de red al servidor central Zabbix en E1.

Este directorio contiene los anexos técnicos oficiales del componente E3 para la entrega académica (configuraciones operativas, scripts de administración y lote de evidencias validadas).

---

## 1. Estructura de Anexos del Componente

```text
E3 - Multi-WAN/
├── README.md                          # Este índice y documentación técnica del componente
├── config/                            # Archivos reales de configuración de Debian / Linux
│   ├── multiwan.env                   # Variables de entorno e interfaces WAN / LAN
│   ├── policies.txt                   # Matriz de enrutamiento basado en políticas (PBR)
│   └── zabbix_multiwan.conf           # Configuración y UserParameters de Zabbix Agent
├── docs/                              # Manual técnico exhaustivo
│   └── documentacion-tecnica-E3.md    # Especificación completa de arquitectura y reglas
├── scripts/                           # Toolkit operativo y demonios de alta disponibilidad
│   ├── setup_multiwan.sh              # Inicialización de tablas, reglas PBR, balanceo y NAT
│   ├── failover_daemon.sh             # Demonio autónomo de sondeo (2s) y conmutación atómica
│   ├── apply_policies.py              # Compilador dinámico de políticas PBR hacia nftables
│   ├── teardown_multiwan.sh           # Limpieza y desmontaje limpio de la pila de red
│   ├── setup_zabbix.sh                # Instalador y configurador del servicio zabbix-agent
│   └── zabbix_agent_multiwan.sh       # Extractor de métricas de kernel para Zabbix
└── evidencias/                        # Lote oficial de evidencias técnicas
    ├── README.md                      # Índice detallado de evidencias y hashes SHA-256
    ├── logs/                          # Registros reales de consola y demonios
    │   ├── failover.log               # Registro en tiempo real de eventos de conmutación
    │   └── policies_applied.log       # Registro de compilación y aplicación de políticas PBR
    └── capturas/                      # Capturas de telemetría en Zabbix
        ├── captura-01-zabbix-dashboard-multiwan.png   # Dashboard de tráfico WAN en Zabbix
        ├── captura-02-zabbix-multiwan-latest-data.png # Telemetría de métricas activas
        └── captura-03-monitoreo-zabbix-e3-e1.png      # Monitoreo del flujo E3 a E1
```

---

## 2. Direccionamiento e Interfaces Físicas

| Dispositivo / Interfaz | Zona / Enlace | Dirección IP | Prefijo | Gateway / Peer | Rol Operativo |
|---|---|:---:|:---:|:---:|---|
| `wlp3s0` | WAN 1 (ISP 1) | `192.168.1.10` | `/24` | `192.168.1.1` | Proveedor Principal (Fibra / Wi-Fi alta velocidad) |
| `wlxc006c3bf886a` | WAN 2 (ISP 2) | `172.20.10.2` | `/28` | `172.20.10.1` | Proveedor Secundario (Adaptador Wi-Fi USB) |
| `eno1` | Enlace E3–E5 | `192.168.81.1` | `/30` | `192.168.81.2` (E5) | Tránsito perimetral hacia Firewall E5 |
| `lo` | Localhost | `127.0.0.1` | `/8` | N/A | Interfaz Loopback |

---

## 3. Rutas Estáticas y Tablas de Enrutamiento (`iproute2`)

E3 utiliza la arquitectura `iproute2` con base de datos de políticas de enrutamiento (FIB). Mantiene la tabla `main` y dos tablas de enrutamiento dedicadas para aislar el tráfico de cada proveedor: **Tabla 100 (ISP1)** y **Tabla 200 (ISP2)**.

### A. Tabla `main` (Enrutamiento Local y Retorno Simétrico)
- `default via 192.168.1.1 dev wlp3s0` (Salida administrativa estándar).
- `192.168.81.0/30 dev eno1 proto kernel scope link src 192.168.81.1` (Subred conectada con E5).
- Rutas de retorno simétrico hacia subredes internas mediante el firewall E5 (`192.168.81.2` con atributo `onlink`):
  - `192.168.10.0/24 via 192.168.81.2 dev eno1 onlink` (VLAN 10 — Admin)
  - `192.168.20.0/24 via 192.168.81.2 dev eno1 onlink` (VLAN 20 — Users)
  - `192.168.30.0/24 via 192.168.81.2 dev eno1 onlink` (VLAN 30 — Servers / Zabbix)
  - `192.168.40.0/24 via 192.168.81.2 dev eno1 onlink` (VLAN 40 — Gestión)
  - `192.168.82.0/30 via 192.168.81.2 dev eno1 onlink` (Tránsito E5 ↔ E2 Squid)
  - `192.168.83.0/30 via 192.168.81.2 dev eno1 onlink` (Tránsito E5 ↔ E4 VPN)
  - `192.168.84.0/30 via 192.168.81.2 dev eno1 onlink` (Tránsito E2 ↔ E1 R1 LAN)
  - `10.200.10.0/24 via 192.168.81.2 dev eno1 onlink` (VPN WireGuard Admin)
  - `10.200.20.0/24 via 192.168.81.2 dev eno1 onlink` (VPN WireGuard Users)
  - `172.16.10.0/24 via 192.168.81.2 dev eno1 onlink` (DMZ Servidor WEB01)

### B. Tablas Dedicadas WAN: Tabla 100 (ISP1) y Tabla 200 (ISP2)
- **Tabla 100:**
  - `default via 192.168.1.1 dev wlp3s0`
  - `192.168.1.0/24 dev wlp3s0 scope link src 192.168.1.10` (Ruta conectada link-scope para L2 directo)
  - Retorno simétrico hacia las subredes internas `via 192.168.81.2 onlink dev eno1`
- **Tabla 200:**
  - `default via 172.20.10.1 dev wlxc006c3bf886a`
  - `172.20.10.0/28 dev wlxc006c3bf886a scope link src 172.20.10.2` (Ruta conectada link-scope para L2 directo)
  - Retorno simétrico hacia las subredes internas `via 192.168.81.2 onlink dev eno1`

### C. Reglas de Políticas FIB (`ip rule`)
- `10100: from all fwmark 0x100 lookup 100` (Tráfico marcado para ISP1 consulta Tabla 100).
- `10200: from all fwmark 0x200 lookup 200` (Tráfico marcado para ISP2 consulta Tabla 200).
*(Las prioridades 10100 y 10200 operan por encima de Tailscale [5210–5270] y antes de la tabla main [32766], garantizando precedencia estricta sin conflictos).*

---

## 4. Matriz de Políticas PBR (`config/policies.txt`)

El archivo externo legible [`config/policies.txt`](./config/policies.txt) define el enrutamiento diferenciado según origen, protocolo y servicio:

| Origen | Protocolo | Puerto(s) | ISP Asignado | Marca (`fwmark`) | Propósito |
|---|:---:|:---:|:---:|:---:|---|
| `192.168.20.10`, `192.168.20.11` (Usuarios) | TCP | `80, 443` | **ISP 1** | `0x100` | Tráfico web de alta velocidad por ISP principal |
| `192.168.20.10`, `192.168.20.11` (Usuarios) | UDP | `53` | **ISP 2** | `0x200` | Consultas DNS por enlace secundario |
| `192.168.20.0/24` (Subred VLAN 20) | TCP | `80, 443` | **ISP 1** | `0x100` | Navegación web general por ISP principal |
| `192.168.20.0/24` (Subred VLAN 20) | UDP | `53` | **ISP 2** | `0x200` | Tráfico DNS general por ISP secundario |
| `192.168.10.0/24` (Subred VLAN 10 Admin) | TCP | `443` | **ISP 1** | `0x100` | Tráfico seguro administrativo por ISP principal |
| `192.168.30.0/24` (Subred VLAN 30 Servidores) | TCP | `443` | **ISP 2** | `0x200` | Tráfico seguro de servidores por ISP secundario |
| `10.200.10.0/24` (VPN Clientes Admin) | TCP | `443` | **ISP 1** | `0x100` | Conexiones críticas de administración VPN por ISP1 |
| `10.200.20.0/24` (VPN Clientes Users) | TCP | `80, 443` | **ISP 1** | `0x100` | Tráfico web de clientes VPN por ISP1 |
| `10.200.20.0/24` (VPN Clientes Users) | UDP | `53` | **ISP 2** | `0x200` | DNS de clientes VPN por ISP2 |
| `192.168.83.2` (Host E4 - Túnel ngrok) | TCP / UDP | `443, 53` | **ISP 1** | `0x100` | Túnel persistente ngrok para evitar reconexiones |
| `172.16.10.0/24` (DMZ Servidor WEB01) | TCP | `443` | **ISP 1** | `0x100` | Salida HTTPS de la DMZ por ISP principal |
| *Resto de tráfico no clasificado* | ANY | ANY | **Balanceo 50/50** | `0x100` / `0x200` | Distribución balanceada persistente (`ct mark`) |

---

## 5. Reglas de Firewall y Mangle (`nftables`)

Configuración administrada atómicamente en la tabla `inet xelaju_multiwan`:

1. **Persistencia de Conexión (`ct mark`):**  
   Paquetes pertenecientes a una conexión establecida recuperan su marca con `meta mark set ct mark`, garantizando que conexiones de múltiples paquetes (como sesiones HTTPS y descargas) salgan siempre por el mismo ISP sin romperse.
2. **DNAT para WireGuard VPN hacia E4:**  
   `ip protocol udp dport 51820 dnat ip to 192.168.83.2:51820` en `prerouting_nat`, permitiendo a clientes externos conectarse al túnel VPN de E4 a través de la IP de E3 con retorno simétrico preservado.
3. **Balanceo de Respaldo 50/50:**  
   `meta mark 0 numgen random mod 2 0 meta mark set 0x100` y `meta mark 0 numgen random mod 2 1 meta mark set 0x200` para distribuir flujos nuevos no sujetos a reglas específicas.
4. **SNAT / Masquerade Perimetral Único:**  
   E3 es el único punto donde se realiza traducción de direcciones hacia Internet mediante reglas dinámicas en `postrouting_nat`:
   - `oifname "wlp3s0" masquerade`
   - `oifname "wlx*" masquerade`

---

## 6. Toolkit de Administración y Scripts Operativos

- [`setup_multiwan.sh`](./scripts/setup_multiwan.sh): Inicializa interfaces, tablas 100 y 200, rutas conectadas `scope link src`, retorno simétrico `onlink`, reglas FIB y llama a `apply_policies.py`.
- [`failover_daemon.sh`](./scripts/failover_daemon.sh): Demonio continuo que sondea cada 2 segundos ambos enlaces mediante sondas ICMP (`8.8.8.8` y `1.1.1.1`), ejecuta conmutación atómica de reglas `ip rule` ante caídas y restaura el estado original al recuperar la conectividad.
- [`apply_policies.py`](./scripts/apply_policies.py): Compilador en Python que procesa `policies.txt`, valida rangos CIDR y puertos, e inyecta atómicamente la cadena `pbr_mangle` en `nftables`.
- [`teardown_multiwan.sh`](./scripts/teardown_multiwan.sh): Desmonta tablas, purga reglas `ip rule`, elimina la tabla `inet xelaju_multiwan` en nftables y restaura el estado de red previo.
- [`setup_zabbix.sh`](./scripts/setup_zabbix.sh): Instala y aprovisiona el servicio `zabbix-agent` vinculándolo a `192.168.30.10:10051`.
- [`zabbix_agent_multiwan.sh`](./scripts/zabbix_agent_multiwan.sh): Script auxiliar que extrae contadores de bytes y paquetes de `/sys/class/net/` para ambos enlaces.

---

## 7. Agente Zabbix y Telemetría en Tiempo Real

El servicio `zabbix-agent` configurado mediante [`config/zabbix_multiwan.conf`](./config/zabbix_multiwan.conf) reporta activamente al servidor central en `192.168.30.10`:

| Clave de Métrica (UserParameter) | Fuente en Kernel Linux | Descripción |
|---|---|---|
| `multiwan.isp1.rx_bytes` | `/sys/class/net/wlp3s0/statistics/rx_bytes` | Bytes recibidos en ISP 1 |
| `multiwan.isp1.tx_bytes` | `/sys/class/net/wlp3s0/statistics/tx_bytes` | Bytes transmitidos en ISP 1 |
| `multiwan.isp1.rx_packets` | `/sys/class/net/wlp3s0/statistics/rx_packets` | Paquetes recibidos en ISP 1 |
| `multiwan.isp1.tx_packets` | `/sys/class/net/wlp3s0/statistics/tx_packets` | Paquetes transmitidos en ISP 1 |
| `multiwan.isp2.rx_bytes` | `/sys/class/net/wlxc006c3bf886a/statistics/rx_bytes` | Bytes recibidos en ISP 2 |
| `multiwan.isp2.tx_bytes` | `/sys/class/net/wlxc006c3bf886a/statistics/tx_bytes` | Bytes transmitidos en ISP 2 |
| `multiwan.isp2.rx_packets` | `/sys/class/net/wlxc006c3bf886a/statistics/rx_packets` | Paquetes recibidos en ISP 2 |
| `multiwan.isp2.tx_packets` | `/sys/class/net/wlxc006c3bf886a/statistics/tx_packets` | Paquetes transmitidos en ISP 2 |

---

## 8. Evidencias Técnicas y Validación

El lote oficial de evidencias físicas, capturas de pantalla de Zabbix y registros de ejecución con sus respectivos hashes criptográficos se encuentra documentado en:
[`evidencias/README.md`](./evidencias/README.md).
