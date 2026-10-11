# XelajuNetwork — Infraestructura Corporativa de Red

**Universidad de San Carlos de Guatemala (USAC)**<br>
**Centro Universitario de Occidente (CUNOC)**<br>
**División de Ciencias de la Ingeniería**<br>
**Curso:** Redes de Computadoras 2 — Segundo Semestre 2026<br>
**Proyecto:** Proyecto Final de Laboratorio<br>

---

## 1. Identificación del Proyecto

**XelajuNetwork** es un proyecto integral de infraestructura de red diseñado, implementado y probado por un equipo de cinco estudiantes sobre entornos reales Debian GNU/Linux en modo consola. El sistema simula una red corporativa moderna con múltiples zonas de seguridad, enrutamiento avanzado, servicios perimetrales, control de contenido y alta disponibilidad hacia Internet.

---

## 2. Objetivo General

Diseñar e implementar una solución completa de red que integre de manera interoperable y segura:
- Segmentación en red local mediante VLANs y enrutamiento interno con DHCP restringido.
- Intercepción y filtrado de contenido Web transparente mediante proxy Squid.
- Tolerancia a fallos y balanceo de carga hacia proveedores de Internet mediante Multi-WAN.
- Servicios perimetrales en DMZ y acceso remoto seguro a través de WireGuard VPN con túnel ngrok.
- Seguridad perimetral con filtrado con estado (`nftables`), política por defecto de denegación (`policy drop`) y detección de intrusiones en tiempo real (`Suricata IDS`).
- Plataforma centralizada de monitoreo de telemetría de red con Zabbix.

---

## 3. Descripción de la Arquitectura

La topología del sistema distribuye la red en tres planos principales:
1. **Núcleo Interno (LAN):** Segmentado en 4 VLANs lógicas (Administración, Usuarios, Servidores, Gestión), gobernado por el router R1-LAN (E1) y conectado río arriba a través del proxy Squid (E2).
2. **Núcleo Perimetral (Seguridad y Servicios):** Centralizado en el firewall perimetral (E5), que actúa como punto de confluencia entre la red interna (vía E2), los servicios perimetrales DMZ/VPN (E4) y la salida exterior (E3).
3. **Borde Externo (WAN):** Gestionado por el router Multi-WAN (E3), interconectado a dos proveedores de Internet (ISP1 e ISP2) para redundancia y balanceo de tráfico.

```text
               +-------------------------------------+
               |         Internet (ISP1 / ISP2)      |
               +------------------+------------------+
                                  |
               +------------------v------------------+
               |        E3: Multi-WAN Routing        |
               |        (192.168.81.1 / WANs)        |
               +------------------+------------------+
                                  | Enlace 192.168.81.0/30
               +------------------v------------------+
               |       E5: Firewall Perimetral       |
               |       (nftables & Suricata IDS)     |
               +---------+-----------------+---------+
                         |                 |
  Enlace 192.168.82.0/30 |                 | Enlace 192.168.83.0/30
                         |                 |
+------------------------v----+       +----v------------------------+
|     E2: Proxy Squid         |       |    E4: WireGuard VPN & DMZ  |
|     (Intercepción HTTP)     |       |    (WEB01 con túnel ngrok)  |
+------------------------+----+       +-----------------------------+
                         |
  Enlace 192.168.84.0/30 |
                         |
+------------------------v----+
|     E1: Segmentación LAN    |
|     (VLANs 10,20,30,40,ZBX) |
+-----------------------------+
```

---

## 4. Componentes y Responsabilidades

| Componente | Rol en la Red | Directorio | Responsabilidades Principales |
|:---:|---|:---:|---|
| **E1** | Router LAN y Monitoreo | [`E1/`](./E1/) | Segmentación en 4 VLANs (802.1Q), enrutamiento inter-VLAN, DHCP restringido con reservas MAC en VLAN 20 y servidor Zabbix (`192.168.30.10`). |
| **E2** | Proxy Web Transparente | [`E2/`](./E2/) | Proxy Squid en modo intercepción transparente para HTTP, listas negras diferenciadas para ADMIN y USERS, y portal de logs restringido a ADMIN. |
| **E3** | Borde Multi-WAN | [`E3/`](./E3/) | Enrutamiento multihomed hacia dos ISPs, balanceo por políticas (PBR), conmutación por error (*failover*), Source NAT y métricas a Zabbix. |
| **E4** | VPN WireGuard y DMZ | [`E4/`](./E4/) | Servidor WireGuard con rangos diferenciados (`VPN-ADMIN: 10.200.10.0/24`, `VPN-USERS: 10.200.20.0/24`), servidor DMZ WEB01 y publicación vía túnel ngrok. |
| **E5** | Firewall Perimetral e IDS | [`E5/`](./E5/) | Filtrado perimetral con estado (`nftables`, default drop), doble pasada de VPN, inspección pasiva en tiempo real con Suricata IDS (7.0.10). |

---

## 5. Flujos de Tráfico Principales

1. **Flujo A — Navegación Web Saliente:**<br>
   Los equipos de la LAN (VLAN 10/20) envían peticiones web hacia Internet a través de E1. En E2, el tráfico HTTP (puerto 80) es interceptado de forma transparente por Squid y validado contra listas de dominios. El tráfico autorizado egresa hacia el firewall E5 (donde es inspeccionado por nftables y Suricata) y finalmente hacia E3, que aplica NAT y selecciona el ISP de salida.
2. **Flujo B — Acceso Remoto Seguro por VPN (Doble Pasada):**<br>
   Clientes remotos establecen un túnel WireGuard cifrado hacia E4 cruzando E5 en el puerto UDP 51820 (*Pasada 1*). E4 descifra los paquetes y los reenvía de vuelta hacia E5 (*Pasada 2*), donde el firewall valida la subred de origen (`VPN-ADMIN` con acceso completo; `VPN-USERS` con acceso restringido exclusivamente a VLAN 20 y al servidor web de Intranet en VLAN 30). El tráfico autorizado viaja a través de E2 hacia la LAN en E1.
3. **Flujo C — Publicación de Servicios DMZ con ngrok:**<br>
   El servidor WEB01 reside en la DMZ de E4 (`172.16.10.10`). Un túnel saliente ngrok sobre TLS (puerto 443) iniciado desde el interior publica el sitio web hacia una URL pública en Internet, permitiendo el acceso de usuarios externos sin necesidad de exponer puertos entrantes directos en los routers de borde.

---

## 6. Estructura del Repositorio

```text
xelaju-network/
├── README.md                      # Descripción general y guía académica del proyecto
├── topologia/
│   ├── xelaju-network.drawio      # Diagrama completo editable de la topología (diagrams.net)
│   └── xelaju-network.png         # Exportación visual de alta resolución para el informe
├── tablas/
│   ├── direccionamiento.csv       # Tabla canónica de direcciones IP, interfaces y máscaras
│   ├── rutas.csv                  # Tablas de enrutamiento estático de los cinco nodos
│   └── matriz-seguridad.csv       # Matriz consolidada de políticas de firewall y ACLs
├── E1/                            # Componente: Segmentación LAN, DHCP y Zabbix
│   └── README.md
├── E2/                            # Componente: Proxy Squid Transparente
│   ├── README.md
│   ├── config/
│   ├── scripts/
│   ├── portal/
│   └── evidencias/
├── E3/                            # Componente: Multi-WAN y Balanceo
│   └── README.md
├── E4/                            # Componente: WireGuard VPN y DMZ
│   └── README.md
├── E5/                            # Componente: Firewall Perimetral e IDS Suricata
│   ├── README.md                  # Manual técnico detallado y estado de E5
│   ├── config/                    # Reglas nftables, plantilla interfaces y Suricata
│   ├── scripts/                   # Toolkit operativo (e5-status, e5-firewall, e5-ids, etc.)
│   └── evidencias/                # Registros de Suricata, PCAPs y capturas
└── integracion/                   # Metodología y reporte de pruebas de integración grupal
    ├── README.md
    └── evidencias/
```

---

## 7. Referencias a Topología, Tablas y Evidencias

- **Topología de Red:** Consultar [`topologia/xelaju-network.png`](./topologia/xelaju-network.png) para visualización inmediata del plano de red, y [`topologia/xelaju-network.drawio`](./topologia/xelaju-network.drawio) para edición de diagramas.
- **Tablas Canónicas Compartidas:**
  - Direccionamiento IP: [`tablas/direccionamiento.csv`](./tablas/direccionamiento.csv)
  - Enrutamiento: [`tablas/rutas.csv`](./tablas/rutas.csv)
  - Matriz de Seguridad y Reglas: [`tablas/matriz-seguridad.csv`](./tablas/matriz-seguridad.csv)
- **Evidencias e Integración:**
  - Guía de pruebas y contratos: [`integracion/README.md`](./integracion/README.md)
  - Evidencias de E2: [`E2/evidencias/`](./E2/evidencias/)
  - Evidencias de E5: [`E5/evidencias/`](./E5/evidencias/)

---

## 8. Localización de Archivos Técnicos

Cada estudiante mantiene la implementación de su respectivo componente en su carpeta individual (`E1/` a `E5/`). La configuración funcional y scripts de seguridad perimetral de **E5** se encuentran plenamente documentados e implementados en [`E5/config/`](./E5/config/) y [`E5/scripts/`](./E5/scripts/).
