# Integración Grupal — Pruebas End-to-End y Contratos de Red

**Proyecto:** XelajuNetwork<br>
**Curso:** Redes de Computadoras 2 — CUNOC / USAC<br>
**Objetivo:** Validar la operatividad conjunta y la interoperabilidad técnica de los cinco componentes de la infraestructura (E1 a E5) de acuerdo con los requerimientos del proyecto final.

---

## 1. Alcance de la Integración Grupal

La topología de XelajuNetwork conecta en cascada y perímetro los cinco componentes desarrollados por el equipo:

```text
ISPs (WAN1/WAN2) <-> [E3: Multi-WAN] <-> [E5: Firewall/IDS] <-> [E2: Squid Proxy] <-> [E1: LAN Router] <-> VLANs
                                                  ^
                                                  | (192.168.83.0/30)
                                                  v
                                          [E4: VPN WireGuard / DMZ]
```

Para validar el sistema completo, se establecen tres flujos de tráfico de extremo a extremo (*End-to-End*):

---

## 2. Flujos de Tráfico Principales

### Flujo A: Navegación Web Saliente desde LAN vía Proxy y Multi-WAN
- **Trayectoria:** `Host LAN (VLAN 10/20) -> E1 (Router) -> E2 (Squid Intercept) -> E5 (Firewall/IDS) -> E3 (Multi-WAN) -> Internet`
- **Comportamiento:**
  - El tráfico HTTP (puerto 80) es interceptado de forma transparente por Squid en E2 y evaluado contra listas de dominios permitidos/bloqueados según la VLAN de origen.
  - El tráfico que pasa el filtro egresa a través de E5, donde se aplica inspección con estado e inspección IDS por Suricata.
  - E3 recibe los paquetes y aplica la política de balanceo/enrutamiento hacia el ISP correspondiente, ejecutando Source NAT (Masquerade).

### Flujo B: Acceso Remoto Seguro mediante VPN WireGuard (Doble Pasada)
- **Trayectoria:** `Cliente Remoto (Internet) -> E3 -> E5 -> E4 (WireGuard) -> E5 -> E2 -> E1 -> Host LAN`
- **Comportamiento:**
  - **Pasada 1:** El cliente inicia el túnel cifrado (UDP 51820) cruzando E3 y E5 hacia el servidor WireGuard en E4.
  - **Pasada 2:** E4 descifra el paquete y lo encamina de vuelta por su enlace hacia E5 (`192.168.83.1`).
  - E5 inspecciona la dirección IP descifrada:
    - Si proviene de `10.200.10.0/24` (VPN-ADMIN), se le permite el acceso a todas las VLANs corporativas.
    - Si proviene de `10.200.20.0/24` (VPN-USERS), se le permite únicamente el acceso a VLAN 20 y a la Intranet web (`192.168.30.20`), bloqueando el acceso a VLAN 10.
  - El tráfico transita por E2 (en modo router puro) hasta llegar a E1 y al equipo destino.

### Flujo C: Publicación de Servicios DMZ mediante ngrok
- **Trayectoria:** `Usuario Externo (Internet) -> Nube ngrok -> Túnel TLS -> E4 (WEB01) -> E5 -> E3 -> Internet`
- **Comportamiento:**
  - El servidor web perimetral WEB01 corre en la subred DMZ (`172.16.10.10:8081`).
  - E4 inicia un túnel saliente seguro hacia ngrok (TCP 443), el cual es autorizado por E5 y enrutado por E3.
  - Usuarios externos acceden a la URL pública proporcionada por ngrok sin necesidad de que el laboratorio disponga de una IP pública fija ni de configurar reenvío de puertos entrantes.

---

## 3. Estado de la Integración

| Handoff / Integración | Componentes | Estado | Observaciones / Puntos Pendientes |
|---|:---:|:---:|---|
| **E3 ↔ E1 (Monitoreo)** | E3 -> E5 -> E2 -> E1 | **Verificado bilateralmente** | Script `setup_zabbix.sh` en E3 enviando métricas de ISPs hacia el servidor Zabbix en E1 (`192.168.30.10:10051`). |
| **E4 ↔ E5/E3 (Salida DMZ)** | E4 -> E5 -> E3 | **Verificado bilateralmente** | Tránsito saliente de E4 hacia Internet y establecimiento exitoso de túnel ngrok verificado con respuesta simétrica. |
| **E1 ↔ E2 (LAN / Proxy)** | E1 -> E2 | **Verificado bilateralmente** | Redirección de tráfico HTTP y aplicación de listas de bloqueo de Squid según VLAN. |
| **E2 ↔ E5 (Enlace Perimetral)** | E2 <-> E5 | **Pendiente de Comprobación** | Enlace `192.168.82.0/30` con falta de respuesta ARP/ICMP entre equipos físicos. Hipótesis técnica de cruce de cable o puerto de switch pendiente de verificar en laboratorio. |
| **Prueba Integral Simultánea** | E1 + E2 + E3 + E4 + E5 | **Pendiente** | Prueba concurrente de los Flujos A, B y C con todos los 5 equipos encendidos e interconectados al mismo tiempo en el laboratorio. |

---

## 4. Guía de Ejecución de Pruebas Integrales

Una vez solventada la comprobación física del enlace E2 ↔ E5:

1. **Verificación de Enrutamiento Base:**
   - Realizar pings de extremo a extremo entre interfaces de tránsito consecutivas (`192.168.81.x`, `192.168.82.x`, `192.168.83.x`, `192.168.84.x`).
2. **Prueba de Flujo A:**
   - Desde un cliente en VLAN 20, ejecutar `curl -I http://facebook.com` (debe ser bloqueado por Squid) y `curl -I http://example.com` (debe pasar por Squid, ser detectado por Suricata y salir por E3).
3. **Prueba de Flujo B:**
   - Conectar un cliente remoto a WireGuard con IP `10.200.20.10`. Intentar ping hacia VLAN 10 (debe ser bloqueado y registrado en E5) y hacia VLAN 20 (debe responder).
4. **Prueba de Flujo C:**
   - Abrir la URL pública de ngrok desde un dispositivo externo y verificar la visualización de la página web de WEB01.
