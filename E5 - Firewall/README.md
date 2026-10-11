# E5 — Firewall Perimetral (nftables) + IDS (Suricata)

**Responsable:** Estudiante 5 (E5)  
**Curso:** Redes de Computadoras 2 — CUNOC / USAC  
**Entorno Operativo:** Debian GNU/Linux 13 (trixie) x86_64 — Kernel `6.12.107+deb13-amd64` (Modo Texto)  
**Rol:** Núcleo de seguridad perimetral, filtrado de paquetes con estado (*stateful*), control de accesos interzonas e inspección profunda de intrusiones en tiempo real (*IDS*).

Este directorio contiene configuraciones versionadas, scripts y evidencias documentadas. La correspondencia exacta con los archivos activos de Debian aún no se ha certificado para todas las configuraciones. El informe académico detallado, análisis y conclusiones se presentan en los documentos PDF de Classroom.

---

## 1. Estructura de Anexos del Componente

```text
E5 - Firewall/
├── README.md                      # Este índice del componente
├── config/                        # Archivos de configuración de Debian
│   ├── e5-firewall.nft            # Reglas nftables activas (tabla inet xelaju_e5, policy drop)
│   ├── local.rules                # Regla local de detección Suricata (SID 1000001)
│   └── sysctl-e5.conf             # Parámetro kernel net.ipv4.ip_forward = 1
├── scripts/                       # Toolkit de administración (/usr/local/sbin/)
│   ├── e5-help                    # Guía rápida de referencia en consola
│   ├── e5-status                  # Dashboard integral de hardware, red y servicios
│   ├── e5-firewall                # Wrapper de gestión y verificación atómica de nftables
│   ├── e5-ids                     # Control del servicio e inspección de alertas Suricata
│   ├── e5-capture                 # Captura de paquetes perimetrales en vivo y PCAP
│   └── provisioning/
│       └── setup_ids.sh           # Script de aprovisionamiento automatizado del IDS
└── evidencias/                    # Lote oficial de evidencias (13 archivos validados)
    ├── README.md                  # Índice detallado de evidencias y hashes SHA-256
    ├── logs/                      # 6 registros formateados de consola
    ├── pcap/                      # 7 capturas de tráfico perimetral (Wireshark)
    └── capturas/                  # Capturas visuales de Wireshark GUI
```

---

## 2. Direccionamiento e Interfaces Físicas

| Interfaz Hardware | Zona / Enlace | IP Local E5 | IP Peer | Rol Operativo |
|---|---|:---:|:---:|---|
| `eno2` | Enlace E3–E5 (`192.168.81.0/30`) | `192.168.81.2` | `192.168.81.1` (E3) | Salida WAN predeterminada (`default gateway`) |
| `enxc0eac367f731` | Enlace E2–E5 (`192.168.82.0/30`) | `192.168.82.1` | `192.168.82.2` (E2) | Tránsito hacia Proxy Squid y LAN interna (E1) |
| `enxf8e43ba69459` | Enlace E4–E5 (`192.168.83.0/30`) | `192.168.83.1` | `192.168.83.2` (E4) | Perímetro DMZ (WEB01) y terminación WireGuard VPN |
| `wlo1` | Administración local (Wi-Fi) | `192.168.1.176` | — | Acceso SSH de gestión (fuera de topología) |

### Rutas Estáticas Principales del Kernel
- `default via 192.168.81.1 dev eno2` (Salida a Internet)
- `192.168.10.0/24`, `192.168.20.0/24`, `192.168.30.0/24`, `192.168.40.0/24` via `192.168.82.2` (VLANs LAN)
- `10.200.10.0/24`, `10.200.20.0/24` via `192.168.83.2` (Subredes WireGuard VPN)
- `172.16.10.0/24` via `192.168.83.2` (Subred DMZ WEB01)

---

## 3. Toolkit de Administración (`/usr/local/sbin/`)

- `e5-status`: Monitoreo general de recursos, interfaces `/30`, rutas del kernel, forwarding y estado de servicios.
- `e5-firewall {status|check|show|backup|apply}`: Administración de reglas nftables con validación sintáctica (`nft -c`) y recarga atómica.
- `e5-ids {status|check|rules|alerts|restart}`: Administración de Suricata 7.0.10, verificación de reglas y seguimiento de alertas en tiempo real.
- `e5-capture {live|save|list} [interfaz] [segundos]`: Captura forense perimetral en consola y generación de archivos PCAP rotados.
- `e5-help`: Referencia rápida interactiva con sintaxis, contratos y puertos autorizados.

---

## 4. Evidencias Técnicas

El lote de 13 evidencias validadas (6 logs y 7 PCAPs con hashes SHA-256) se encuentra documentado en:
[`evidencias/README.md`](./evidencias/README.md).

---

## Configuraciones reales pendientes de cotejo

Las plantillas de interfaces y Suricata no demuestran la configuración instalada. Se retiran de esta rama de auditoría hasta recibir las copias verificadas **del equipo E5** de `/etc/network/interfaces`, fragmentos activos de `/etc/network/interfaces.d/` y `/etc/suricata/suricata.yaml`. Las reglas `e5-firewall.nft`, `local.rules` y `sysctl-e5.conf` también requieren comparación con sus rutas efectivas. No reconstruir configuraciones a partir de este README. Validar la sintaxis activa mediante `sudo suricata -T -c /etc/suricata/suricata.yaml`; eso no reemplaza una prueba funcional.
