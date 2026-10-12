# Evidencias de Verificación — E3 (Router Multi-WAN, Failover, NAT y Zabbix)

**Componente:** E3 — Router de Borde Multi-WAN, PBR, Failover y SNAT Perimetral  
**Responsable:** Estudiante 3 (E3)  
**Curso:** Redes de Computadoras 2 — CUNOC / USAC  
**Entorno Operativo:** Debian GNU/Linux (Modo Consola / Texto)  

Este documento indexa el lote oficial de evidencias técnicas recolectadas durante las pruebas de conectividad física, enrutamiento basado en políticas (PBR), conmutación por error (*failover*), persistencia con *connection tracking* y telemetría en tiempo real hacia Zabbix.

---

## 1. Estructura del Lote de Evidencias

```text
E3 - Multi-WAN/evidencias/
├── README.md                                          # Este índice oficial y tabla de hashes
├── logs/                                              # Registros operativos de consola y demonios
│   ├── failover.log                                   # Registro en tiempo real de caídas y recuperaciones WAN
│   └── policies_applied.log                           # Compilación y carga atómica de políticas PBR en nftables
└── capturas/                                          # Capturas de telemetría y monitoreo
    ├── captura-01-zabbix-dashboard-multiwan.png       # Gráficas de tráfico ISP1 e ISP2 en Zabbix Dashboard
    ├── captura-02-zabbix-multiwan-latest-data.png     # Telemetría en tiempo real (Latest Data) de E3
    └── captura-03-monitoreo-zabbix-e3-e1.png          # Tráfico perimetral E3->E1 capturado en E5
```

---

## 2. Matriz de Evidencias y Pruebas Técnicas Validadas

| ID | Requerimiento / Prueba | Comando o Fuente | Resultado Comprobado | Cumplimiento |
|:---:|---|---|---|:---:|
| **E1** | Direccionamiento de interfaces WAN y LAN | `ip -br addr` | `wlp3s0` (`192.168.1.10/24`), `wlxc006c3bf886a` (`172.20.10.2/28`), `eno1` (`192.168.81.1/30`) | ✅ Conforme a topología |
| **E2** | Salida concurrente con IPs públicas distintas | `curl --interface wlp3s0 https://api.ipify.org`<br>`curl --interface wlxc006c3bf886a https://api.ipify.org` | ISP1: `190.143.186.95`<br>ISP2: `181.174.73.105` | ✅ 2 ISPs reales e independientes |
| **E3** | Reglas PBR en base de datos FIB (`ip rule`) | `ip rule show` | `10100: from all fwmark 0x100 lookup 100`<br>`10200: from all fwmark 0x200 lookup 200` | ✅ Prioridades 10100 y 10200 activas |
| **E4** | Tablas de enrutamiento 100 y 200 | `ip route show table 100`<br>`ip route show table 200` | Tabla 100: `default via 192.168.1.1` + `scope link src`<br>Tabla 200: `default via 172.20.10.1` + `scope link src` | ✅ Tablas 100 y 200 aisladas |
| **E5** | Retorno simétrico hacia subredes internas | `ip route show table main \| grep onlink` | Rutas `onlink` hacia VLANs 10, 20, 30, 40, DMZ y VPNs vía `192.168.81.2` | ✅ Retorno por firewall E5 |
| **E6** | Mangle, balanceo y DNAT en `nftables` | `sudo nft list table inet xelaju_multiwan` | DNAT UDP 51820 hacia E4, persistencia `ct mark`, balanceo 50/50 `numgen random mod 2` | ✅ Estado de conexiones preservado |
| **E7** | Masquerade perimetral centralizado | `sudo nft list chain inet xelaju_multiwan postrouting_nat` | Reglas SNAT / Masquerade en `wlp3s0` y `{ "enx*", "usb*", "wlx*" }` | ✅ Único punto de NAT del sistema |
| **E8** | Conmutación por falla del Demonio de Failover | [`logs/failover.log`](./logs/failover.log) | Conmutación atómica de reglas `ip rule` ante caída en $\le 2$ s y recuperación automática | ✅ Tolerancia a fallos demostrada |
| **E9** | Conectividad punto a punto con Firewall E5 | `ping -c 3 192.168.81.2` | 3 paquetes transmitidos, 3 recibidos, 0% packet loss, RTT avg = 0.31 ms | ✅ Enlace físico /30 verificado |
| **E10** | Traza extremo a extremo cruzando los 5 nodos | `traceroute -T -p 443 -s 192.168.20.1 1.1.1.1` | R1 (`192.168.84.1`) → E2 → E5 (`192.168.82.1`) → E3 (`192.168.81.1`) → ISP → Cloudflare | ✅ Cadena de 5 nodos operativa |
| **E11** | Exportación de telemetría hacia Zabbix | `zabbix_agentd -t multiwan.isp1.rx_bytes`<br>[`capturas/captura-01...`](./capturas/captura-01-zabbix-dashboard-multiwan.png) | 8 métricas activas de kernel transmitidas a `192.168.30.10:10051`, graficadas en panel central | ✅ Monitoreo centralizado activo |

---

## 3. Integridad Criptográfica (SHA-256)

| Archivo | Hash SHA-256 |
|---|---|
| `logs/failover.log` | `af9cbd7caeeba087de980f71ca56d8a7e24e434273c39cdb1dacc580345a6f6b` |
| `logs/policies_applied.log` | `5ff183cac0cc529a006ae9883d523c212145525d76ba3ce5f918d0cbb1ae5fb7` |
| `capturas/captura-01-zabbix-dashboard-multiwan.png` | `8e3a468fdb989f56435a18c739ecdfe306ca61f6b7ae3afeabb04229a0111b81` |
| `capturas/captura-02-zabbix-multiwan-latest-data.png` | `e477a2d3218ad4600b227d116472922033248611a3c7c249c9159c81ce37292c` |
| `capturas/captura-03-monitoreo-zabbix-e3-e1.png` | `8c4c36b1de2b350962f3ce3ba1e7a65b709489efc2a59f596b4f270e0546921c` |
