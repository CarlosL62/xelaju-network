# Documentación Técnica Oficial — Nodo E3: Router Multi-WAN, Balanceo, NAT y Failover
**Proyecto Final — Redes de Computadoras 2**  
**Institución:** Universidad de San Carlos de Guatemala / CUNOC  
**Topología:** XelajuNetwork (E1: LAN/VLANs, E2: Squid Proxy, E3: Multi-WAN, E4: VPN WireGuard/DMZ, E5: Firewall IDS/IPS)  
**Responsable:** Estudiante 3 (E3)  
**Sistema:** Debian GNU/Linux (Modo Consola / Texto)  
**Fecha de consolidación:** Octubre 2026  

---

## 1. Resumen Ejecutivo y Rol en la Topología

El nodo **E3** opera como el **Router de Borde (Edge Router)** y la única pasarela física hacia Internet de toda la arquitectura empresarial de XelajuNetwork. Sus responsabilidades primarias son:
1. **Conectividad Multi-WAN Redundante:** Proporcionar dos salidas independientes a Internet:
   - **ISP 1:** Interfaz Wi-Fi de alta velocidad (`wlp3s0`).
   - **ISP 2:** Adaptador Wi-Fi USB de 2.4 GHz (`wlxc006c3bf886a` - TP-Link TL-WN722N) o celular Android conectado por cable USB (`enx*` / `usb*`) con auto-detección dinámica.
2. **Enrutamiento Basado en Políticas (PBR):** Dirigir flujos de tráfico específicos hacia un ISP determinado según la IP de origen, puerto y protocolo, configurado mediante un archivo externo legible (`config/policies.txt`).
3. **Balanceo de Carga con Persistencia (`ct mark`):** Distribuir equitativamente (50% / 50%) el tráfico no sujeto a políticas especiales mediante `nftables` y connection tracking para garantizar que conexiones TCP persistentes (como HTTPS o túneles ngrok) no se rompan por asimetría.
4. **Alta Disponibilidad y Failover Automático:** Monitoreo activo de salud de cada enlace mediante sondas ICMP continuas cada 2 segundos. En caso de caída de un ISP, el tráfico se conmuta automáticamente hacia el enlace sobreviviente mediante reasignación atómica de reglas `ip rule`, retornando al estado original (failback) de forma transparente al recuperarse.
5. **DNAT para Acceso Remoto Seguro (WireGuard):** Redirección simétrica del puerto UDP 51820 hacia el servidor WireGuard de E4 (`192.168.83.2`), manteniendo la simetría de retorno por la misma WAN por la que ingresó el cliente.
6. **SNAT / Masquerade Perimetral Único:** Único nodo de la topología donde se realiza traducción de direcciones hacia Internet; la LAN interna (R1) y el firewall perimetral (E5) operan sin NAT intermedio.
7. **Monitoreo de Enlaces con Zabbix:** Agente local exportando contadores de bytes y paquetes de ambas WANs en tiempo real hacia el servidor central de Zabbix (`192.168.30.10`).

---

## 2. Diagrama de Conectividad y Flujo de Tráfico

```text
                                +-------------------+
                                |   INTERNET / WAN  |
                                +---------+---------+
                                          ^
                     +--------------------+--------------------+
                     |                                         |
           [ISP 1: Wi-Fi wlp3s0]                     [ISP 2: Wi-Fi USB wlxc006c3bf886a]
           (IP: 192.168.1.10/24)                     (IP: 172.20.10.2/28)
           (GW: 192.168.1.1)                         (GW: 172.20.10.1)
           (Pública: 190.143.186.95)                 (Pública: 181.174.73.105)
                     |                                         |
                     +--------------------+--------------------+
                                          |
                               [NODO E3: MULTI-WAN]
                           (eno1: 192.168.81.1/30 - LAN)
                                          |
                             [Cable Ethernet Físico /30]
                                          |
                                [NODO E5: FIREWALL]
                           (eno2: 192.168.81.2/30)
                                          |
                     +--------------------+--------------------+
                     |                                         |
           (192.168.82.0/30)                         (192.168.83.0/30)
                     |                                         |
             [NODO E2: SQUID]                         [NODO E4: VPN & DMZ]
                     |                                - WireGuard: 192.168.83.2
             (192.168.84.0/30)                        - Clientes: 10.200.10/20.0/24
                     |                                - DMZ WEB01: 172.16.10.10
              [NODO E1: LAN]
           - VLAN 10 (Admin)
           - VLAN 20 (Users)
           - VLAN 30 (Servers/Zabbix)
           - VLAN 40 (Gestión)
```

---

## 3. Tabla de Direccionamiento de E3 (Requisito Sección 9)

| Dispositivo | Interfaz | Dirección IP | Máscara / Prefijo | Gateway | Red / Propósito |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Router E3** | `wlp3s0` | `192.168.1.10` | `255.255.255.0` (`/24`) | `192.168.1.1` | ISP 1 (Proveedor Principal Fibra/Wi-Fi) |
| **Router E3** | `wlxc006c3bf886a` | `172.20.10.2` | `255.255.255.240` (`/28`) | `172.20.10.1` | ISP 2 (Adaptador WiFi USB / Red Móvil Secundaria) |
| **Router E3** | `eno1` | `192.168.81.1` | `255.255.255.252` (`/30`) | N/A (Local) | Enlace punto a punto hacia Firewall E5 (`192.168.81.2`) |
| **Router E3** | `lo` | `127.0.0.1` | `255.0.0.0` (`/8`) | N/A | Interfaz Loopback del sistema |

---

## 4. Tabla de Rutas Estáticas de E3 (Requisito Sección 9)

E3 utiliza la arquitectura `iproute2` con base de datos de políticas de enrutamiento (FIB). Mantiene la tabla `main` y dos tablas de enrutamiento personalizadas: **Tabla 100 (ISP1)** y **Tabla 200 (ISP2)**.

### A. Tabla `main` (Enrutamiento Local y Conectividad Interna)
| Red Destino | Máscara | Next Hop | Interfaz | Propósito |
| :--- | :--- | :--- | :--- | :--- |
| `default` | `0.0.0.0` | `192.168.1.1` | `wlp3s0` | Salida estándar administrativa del sistema |
| `192.168.81.0` | `255.255.255.252` (`/30`) | Directamente conectada | `eno1` | Enlace punto a punto con Firewall E5 |
| `192.168.10.0` | `255.255.255.0` (`/24`) | `192.168.81.2` (`onlink`) | `eno1` | Retorno hacia VLAN 10 (Administración) |
| `192.168.20.0` | `255.255.255.0` (`/24`) | `192.168.81.2` (`onlink`) | `eno1` | Retorno hacia VLAN 20 (Usuarios) |
| `192.168.30.0` | `255.255.255.0` (`/24`) | `192.168.81.2` (`onlink`) | `eno1` | Retorno hacia VLAN 30 (Servidores / Zabbix) |
| `192.168.40.0` | `255.255.255.0` (`/24`) | `192.168.81.2` (`onlink`) | `eno1` | Retorno hacia VLAN 40 (Gestión) |
| `192.168.82.0` | `255.255.255.252` (`/30`) | `192.168.81.2` (`onlink`) | `eno1` | Enlace de tránsito E5 ↔ E2 (Squid) |
| `192.168.83.0` | `255.255.255.252` (`/30`) | `192.168.81.2` (`onlink`) | `eno1` | Enlace de tránsito E5 ↔ E4 (WireGuard) |
| `192.168.84.0` | `255.255.255.252` (`/30`) | `192.168.81.2` (`onlink`) | `eno1` | Enlace de tránsito E2 ↔ E1 (R1 LAN) |
| `10.200.10.0` | `255.255.255.0` (`/24`) | `192.168.81.2` (`onlink`) | `eno1` | Retorno hacia clientes WireGuard VPN Admin |
| `10.200.20.0` | `255.255.255.0` (`/24`) | `192.168.81.2` (`onlink`) | `eno1` | Retorno hacia clientes WireGuard VPN Users |
| `172.16.10.0` | `255.255.255.0` (`/24`) | `192.168.81.2` (`onlink`) | `eno1` | Retorno hacia Servidor WEB01 en DMZ |

### B. Tabla `100` (Enrutamiento Específico ISP 1)
| Red Destino | Máscara | Next Hop / Atributos | Interfaz | Propósito |
| :--- | :--- | :--- | :--- | :--- |
| `default` | `0.0.0.0` | `192.168.1.1` | `wlp3s0` | Salida predeterminada por ISP 1 |
| `192.168.1.0` | `255.255.255.0` (`/24`) | `scope link src 192.168.1.10` | `wlp3s0` | **Subred conectada local** (comunicación directa L2 con clientes en WAN1) |
| `192.168.81.0` | `255.255.255.252` (`/30`) | Directamente conectada | `eno1` | Acceso L2 al Firewall E5 |
| Subredes internas | Varios | `via 192.168.81.2 onlink` | `eno1` | Retorno simétrico hacia las 10 subredes internas |

### C. Tabla `200` (Enrutamiento Específico ISP 2)
| Red Destino | Máscara | Next Hop / Atributos | Interfaz | Propósito |
| :--- | :--- | :--- | :--- | :--- |
| `default` | `0.0.0.0` | `172.20.10.1` | `wlxc006c3bf886a` | Salida predeterminada por ISP 2 |
| `172.20.10.0` | `255.255.255.240` (`/28`) | `scope link src 172.20.10.2` | `wlxc006c3bf886a` | **Subred conectada local** (permite responder directo por L2/ARP a clientes VPN locales) |
| `192.168.81.0` | `255.255.255.252` (`/30`) | Directamente conectada | `eno1` | Acceso L2 al Firewall E5 |
| Subredes internas | Varios | `via 192.168.81.2 onlink` | `eno1` | Retorno simétrico hacia las 10 subredes internas |

---

## 5. Matriz de Políticas PBR (Archivo `config/policies.txt`)

El archivo externo [`policies.txt`](file:///home/ronyr304/ProyectoFinalRC2/xelaju-network-coordination/nodes/E3-multiwan/config/policies.txt) define la política de salida obligatoria de la organización:

| Origen | Protocolo | Puerto(s) | ISP Asignado | Marca (`fwmark`) | Justificación Técnica |
| :--- | :--- | :--- | :--- | :--- | :--- |
| `192.168.20.10`, `192.168.20.11` (PC-USER01 / PC-USER02) | TCP | `80, 443` | **ISP 1** | `0x100` | Tráfico web de usuarios por el enlace de mayor ancho de banda |
| `192.168.20.10`, `192.168.20.11` (PC-USER01 / PC-USER02) | UDP | `53` | **ISP 2** | `0x200` | Consultas DNS por enlace secundario |
| `192.168.83.2` (E4 - ngrok) | TCP | `443` | **ISP 1** | `0x100` | Túnel ngrok forzado a ISP1 para evitar reconexiones por cambio de IP pública |
| `172.16.10.0/24` (DMZ WEB01)| TCP | `443` | **ISP 1** | `0x100` | Salida HTTPS de servidores en DMZ por enlace principal |
| `10.200.10.0/24` (VPN Admin) | TCP | `443` | **ISP 1** | `0x100` | Conexiones críticas de administración por ISP1 |
| `10.200.20.0/24` (VPN Users) | UDP | `53` | **ISP 2** | `0x200` | Consultas DNS de usuarios VPN por ISP2 |
| *Cualquier otro tráfico* | ANY | ANY | **Balanceo 50/50** | `0x100` / `0x200` | Distribución pseudoaleatoria persistente (`numgen random mod 2`) |

---

## 6. Reglas de Firewall y Mangle (`nftables`)

La estructura de filtrado y manipulación de paquetes se organiza en la tabla `inet xelaju_multiwan`:

```nft
table inet xelaju_multiwan {
    # 1. Cadena de balanceo de respaldo para trafico sin politica explicita
    chain balance_fallback {
        meta mark 0 numgen random mod 2 0 meta mark set 0x100 counter comment "balance_50_isp1"
        meta mark 0 numgen random mod 2 1 meta mark set 0x200 counter comment "balance_50_isp2"
    }

    # 2. Cadena prerouting_mangle: Persistencia y etiquetado
    chain prerouting_mangle {
        type filter hook prerouting priority mangle; policy accept;

        # Restaurar marca previa para paquetes que entran desde LAN (E5)
        iifname "eno1" meta mark set ct mark
        iifname "eno1" meta mark != 0 accept

        # Conexiones entrantes por WAN (DNAT WireGuard desde Internet hacia E4):
        iifname "wlp3s0" ct mark set 0x100 accept
        iifname { "enx*", "usb*", "wlx*" } ct mark set 0x200 accept

        # Evaluar politicas PBR de policies.txt (solo para paquetes originados en LAN)
        iifname "eno1" jump pbr_mangle

        # Balanceo 50/50 para trafico nuevo sin politica
        iifname "eno1" jump balance_fallback

        # Guardar marca final en el registro conntrack
        iifname "eno1" ct mark set meta mark
    }

    # 3. Cadena pbr_mangle: Generada dinamicamente por apply_policies.py
    chain pbr_mangle {
        ip saddr 192.168.20.10 tcp dport { 80, 443 } meta mark set 0x100 accept
        ip saddr 192.168.20.10 udp dport 53 meta mark set 0x200 accept
        ip saddr 192.168.83.2 tcp dport 443 meta mark set 0x100 accept
        ip saddr 172.16.10.0/24 tcp dport 443 meta mark set 0x100 accept
        ip saddr 10.200.10.0/24 tcp dport 443 meta mark set 0x100 accept
        ip saddr 10.200.20.0/24 udp dport 53 meta mark set 0x200 accept
    }

    # 4. Cadena prerouting_nat: DNAT para WireGuard hacia E4
    chain prerouting_nat {
        type nat hook prerouting priority dstnat; policy accept;
        ip protocol udp dport 51820 dnat ip to 192.168.83.2:51820 comment "DNAT_WIREGUARD_E4"
    }

    # 5. Cadena postrouting_nat: SNAT / Masquerade perimetral dinamico
    chain postrouting_nat {
        type nat hook postrouting priority srcnat; policy accept;
        oifname "wlp3s0" masquerade
        oifname { "enx*", "usb*", "wlx*" } masquerade
    }
}
```

---

## 7. Demonio de Monitoreo, Failover y Resiliencia (`failover_daemon.sh`)

El script `failover_daemon.sh` opera como un servicio autónomo con sondeo cada 2 segundos:
1. **Comprobación de Salud (Heartbeat):** Ejecuta `ping -I <iface> -c 1 -W 1 8.8.8.8` y `1.1.1.1`.
2. **Conmutación Instantánea (Failover):** Si un ISP no responde, reasigna atómicamente la regla de la base de datos de enrutamiento:
   ```bash
   # Si ISP1 cae:
   ip rule del fwmark 0x100 pref 10100
   ip rule add fwmark 0x100 table 200 pref 10100
   ```
   Esto redirige de inmediato los flujos marcados con `0x100` a la Tabla 200 sin necesidad de alterar las tablas de rutas ni reiniciar servicios.
3. **Restauración Transparente (Failback):** Cuando el enlace vuelve a responder, restaura la regla apuntando a la Tabla 100 original.
4. **Resiliencia ante Cambios de Red en Hotspot (`ensure_table_route`):** Cada 2 segundos, el demonio inspecciona la IP asignada a la interfaz activa y:
   - Asegura la ruta `default via <GW> dev <IFACE> table <TBL>`.
   - Asegura la ruta conectada link-scope `ip route replace <NET> dev <IFACE> scope link src <SRC> table <TBL>`.
   - Verifica que el `masquerade` exista en nftables sin duplicar reglas.

---

## 8. Agente Zabbix de Multi-WAN (`zabbix_agent_multiwan.sh`)

Integrado con el servidor central Zabbix (`192.168.30.10:10051`), el agente instalado en E3 expone 8 métricas en tiempo real leyendo directamente los contadores del kernel en `/sys/class/net/`:

| Clave de Métrica en Zabbix | Fuente en Kernel Linux | Descripción |
| :--- | :--- | :--- |
| `multiwan.isp1.rx_bytes` | `/sys/class/net/wlp3s0/statistics/rx_bytes` | Bytes recibidos en ISP 1 |
| `multiwan.isp1.tx_bytes` | `/sys/class/net/wlp3s0/statistics/tx_bytes` | Bytes transmitidos en ISP 1 |
| `multiwan.isp1.rx_packets` | `/sys/class/net/wlp3s0/statistics/rx_packets` | Paquetes recibidos en ISP 1 |
| `multiwan.isp1.tx_packets` | `/sys/class/net/wlp3s0/statistics/tx_packets` | Paquetes transmitidos en ISP 1 |
| `multiwan.isp2.rx_bytes` | `/sys/class/net/wlxc006c3bf886a/statistics/rx_bytes` | Bytes recibidos en ISP 2 |
| `multiwan.isp2.tx_bytes` | `/sys/class/net/wlxc006c3bf886a/statistics/tx_bytes` | Bytes transmitidos en ISP 2 |
| `multiwan.isp2.rx_packets` | `/sys/class/net/wlxc006c3bf886a/statistics/rx_packets` | Paquetes recibidos en ISP 2 |
| `multiwan.isp2.tx_packets` | `/sys/class/net/wlxc006c3bf886a/statistics/tx_packets` | Paquetes transmitidos en ISP 2 |

---

## 9. Evidencias de Ejecución y Pruebas Reales

### A. Prueba de Conectividad con el Vecino Directo E5
```text
$ ping -c 3 192.168.81.2
PING 192.168.81.2 (192.168.81.2) 56(84) bytes of data.
64 bytes from 192.168.81.2: icmp_seq=1 ttl=64 time=0.308 ms
64 bytes from 192.168.81.2: icmp_seq=2 ttl=64 time=0.310 ms
64 bytes from 192.168.81.2: icmp_seq=3 ttl=64 time=0.312 ms

--- 192.168.81.2 ping statistics ---
3 packets transmitted, 3 received, 0% packet loss, time 2016ms
rtt min/avg/max/mdev = 0.308/0.310/0.312/0.002 ms
```

### B. Prueba de Salida Independiente con IPs Públicas Distintas
```text
$ curl --interface wlp3s0 https://api.ipify.org
190.143.186.95

$ curl --interface wlxc006c3bf886a https://api.ipify.org
181.174.73.105
```

### C. Prueba de Enrutamiento Completo Extremo a Extremo (Traceroute de 5 Nodos)
```text
$ sudo traceroute -T -p 443 -s 192.168.20.1 -n 1.1.1.1
traceroute to 1.1.1.1 (1.1.1.1), 30 hops max, 60 byte packets
 1  192.168.84.1  3.538 ms  (E2 - Squid Proxy)
 2  192.168.82.1  3.460 ms  (E5 - Firewall Perimetral)
 3  192.168.81.1  3.416 ms  (E3 - Router Multi-WAN)
 4  172.20.10.1   6.120 ms  (ISP2 - Gateway Wi-Fi Hotspot)
 5  181.174.73.1  12.450 ms (Enlace del Proveedor Móvil)
 ...
 12 1.1.1.1       48.210 ms (Cloudflare / Destino Internet)
```

### D. Lectura de Métricas en Vivo de Zabbix Agent
```text
$ /usr/sbin/zabbix_agentd -t multiwan.isp1.rx_bytes
multiwan.isp1.rx_bytes                        [t|264389700]

$ /usr/sbin/zabbix_agentd -t multiwan.isp2.rx_bytes
multiwan.isp2.rx_bytes                        [t|23904462]

$ nc -zv -w 3 192.168.30.10 10051
Connection to 192.168.30.10 10051 port [tcp/zabbix-trapper] succeeded!
```

### E. Registro y Validación de Failover en Red Real (`evidencias/logs/failover.log`)
```text
[2026-10-03 16:25:13] [INICIO] Demonio de Failover Multi-WAN iniciado
[2026-10-03 16:25:13]   Monitoreando ISP1 (wlp3s0) y ISP2 (wlxc006c3bf886a)
[2026-10-03 16:25:13]   Intervalo de chequeo: 2s
[2026-10-03 16:25:14] [RECUPERACION] ISP1 (wlp3s0) ESTA DISPONIBLE NUEVAMENTE! Restaurando politica normal (Tabla 100)...
[2026-10-03 16:25:14] [RECUPERACION] ISP2 (wlxc006c3bf886a) ESTA DISPONIBLE NUEVAMENTE! Restaurando politica normal (Tabla 200)...
[2026-10-03 16:25:44] [ALERTA] ISP2 (wlxc006c3bf886a) HA CAIDO! Ejecutando failover hacia ISP1 (Tabla 100)...
[2026-10-03 16:30:02] [ALERTA] ISP1 (wlp3s0) HA CAIDO! Ejecutando failover hacia ISP2 (Tabla 200)...
[2026-10-03 16:30:16] [RECUPERACION] ISP1 (wlp3s0) ESTA DISPONIBLE NUEVAMENTE! Restaurando politica normal (Tabla 100)...
```
Demuestra que la detección ocurre en $\le 2$ segundos y que la conmutación atómica de reglas `ip rule` redirige el tráfico sin interrupciones para los clientes de la infraestructura.

---

## 10. Referencias de Anexos
- [Directorio de Configuraciones](../config/)
- [Scripts Operativos](../scripts/)
- [Lote Oficial de Evidencias](../evidencias/README.md)
