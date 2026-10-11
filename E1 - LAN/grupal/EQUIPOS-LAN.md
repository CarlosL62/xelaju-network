# Equipos de la LAN (E1): direcciones, servicios y quién llega a cada uno

Referencia rápida para los compañeros: qué equipo es cada VM de la LAN, qué dirección tiene, qué servicio ofrece y desde dónde se puede probar.

Esta nota **no define ningún valor**. Las VLAN, las puertas de enlace, el enlace con E2 y la IP de Zabbix salen del plan de direccionamiento del grupo ([`tablas/direccionamiento.csv`](../../tablas/direccionamiento.csv)); las direcciones de cada VM, de `lab/topologia.conf`. `pruebas/consistencia.py` falla si esta tabla deja de coincidir con la topología. La tabla completa por interfaz, con máscaras y MAC, está en [`docs/01-diseno-red.md`](../docs/01-diseno-red.md), sección 3.

Comprobado contra las VMs encendidas el 10 de octubre de 2026 (`ip -4 addr` y puertos en escucha en cada una).

## 1. Los equipos

| Equipo | Qué es | VLAN | Dirección | Puerta de enlace | Cómo recibe la IP | Servicios que escucha |
|---|---|---|---|---|---|---|
| R1-LAN | Router entre VLAN, ACL y DHCP | 10, 20, 30, 40 | `192.168.10.1`, `192.168.20.1`, `192.168.30.1`, `192.168.40.1` (una por VLAN) | — | Manual | SSH 22 (solo ADMIN y GESTIÓN); DHCP solo en la VLAN 20 |
| R1-LAN, enlace con el grupo | Único enlace de la LAN hacia E2 | — | `192.168.84.2/30` | `192.168.84.1` (E2) | Manual | Responde ping a los enlaces de tránsito |
| SW-CORE01 | Switch de núcleo | 40 (gestión) | `192.168.40.2` | `192.168.40.1` | Manual | SSH 22 |
| SW-ACC01 | Switch de acceso | 40 (gestión) | `192.168.40.3` | `192.168.40.1` | Manual | SSH 22 |
| ZBX-SRV01 | Servidor Zabbix 7.0 | 30 | `192.168.30.10` | `192.168.30.1` | Manual | TCP 10051 (agentes activos); web en TCP 80, solo para la VLAN ADMIN |
| SRV-INTRA01 | Intranet (nginx) | 30 | `192.168.30.20` | `192.168.30.1` | Manual | HTTP 80, HTTPS 443, SSH 22 |
| PC-ADMIN01 | PC de administración, con escritorio | 10 | `192.168.10.50` | `192.168.10.1` | Manual | SSH 22; responde ping |
| PC-USER01 | PC de usuario, con escritorio | 20 | `192.168.20.10` | `192.168.20.1` | DHCP, reserva para `aa:bb:cc:dd:ee:01` | SSH 22; responde ping |
| PC-USER02 | PC de usuario | 20 | `192.168.20.11` | `192.168.20.1` | DHCP, reserva para `aa:bb:cc:dd:ee:02` | SSH 22; responde ping |
| PC-USER03 | Reserva sin VM (equipo de pruebas de E3) | 20 | `192.168.20.12` | `192.168.20.1` | DHCP, reserva para `aa:bb:cc:dd:ee:03` | — |
| PC-MGMT01 | PC de gestión, solo consola | 40 | `192.168.40.10` | `192.168.40.1` | Manual | SSH 22 |
| PC-INTRUSO | Equipo no registrado, para las pruebas del DHCP restringido | 20 | ninguna | — | Pide DHCP y nadie le contesta (`aa:bb:cc:dd:ee:99`) | — |

Notas:

- Todas las redes de VLAN son `/24`. No hay rango dinámico: en la VLAN 20 solo reciben dirección las tres MAC registradas.
- En modo individual (sin el grupo) R1 sale por `tmp-nat`, `10.0.2.15/24`, y hace NAT. En modo grupal esa interfaz está apagada y **R1 no hace NAT**: Squid, el firewall y el Multi-WAN ven las direcciones de esta tabla.
- Lo que origina el propio R1 (por ejemplo, su `apt`) sale con `192.168.84.2`.
- Usuario de todas las VMs: `xelaju`, con `sudo`. La contraseña no está en el repositorio.

## 2. Destinos útiles para las pruebas del grupo

Lo que debe ocurrir al probar cada destino. "Decide" indica quién aplica la regla: R1 (E1) o el firewall (E5).

| Destino | Prueba | Llega | No llega | Decide |
|---|---|---|---|---|
| `192.168.10.50` PC-ADMIN01 | ping | VPN-ADMIN | VPN-USERS, DMZ, E2 y E3 | E5; R1 para la DMZ y los enlaces de tránsito |
| `192.168.20.10` PC-USER01 | ping, SSH 22 | VPN-ADMIN y VPN-USERS | DMZ | E5 |
| `192.168.30.10` ZBX-SRV01 | ping | VPN-ADMIN | VPN-USERS | E5 |
| `192.168.30.10` ZBX-SRV01 | web `http://192.168.30.10/zabbix/` | Solo la VLAN ADMIN | Todo lo demás, también VPN-ADMIN | R1 |
| `192.168.30.10` ZBX-SRV01 | TCP 10051 (agente de Zabbix) | Los enlaces de tránsito `192.168.81.0/30` a `192.168.84.0/30` | — | E5 y R1 |
| `192.168.30.20` SRV-INTRA01 | HTTP 80, HTTPS 443 | VPN-ADMIN, VPN-USERS, VLAN ADMIN y USUARIOS | DMZ | E5; R1 dentro de la LAN |
| `192.168.30.20` SRV-INTRA01 | SSH 22 | VPN-ADMIN, VLAN ADMIN y GESTIÓN | VPN-USERS, VLAN USUARIOS | E5; R1 dentro de la LAN |
| `192.168.40.2` SW-CORE01 | SSH 22 | VPN-ADMIN, VLAN ADMIN y GESTIÓN | VPN-USERS, VLAN USUARIOS | E5; R1 dentro de la LAN |
| `192.168.84.2` R1-LAN | ping | E2 y E5. R1 lo acepta desde los cuatro enlaces de tránsito; que E3 y E4 lleguen depende de que E5 lo reenvíe | — | R1 y E5 |
| `192.168.84.2` R1-LAN | SSH 22 | Nadie desde fuera de la LAN | E2 y los demás | R1 |

Los mismos casos, con su identificador, están en `matriz-grupal.conf` y en `pruebas-grupales.md`. La política completa entre VLAN: `docs/01-diseno-red.md`, sección 6.

## 3. Desde la LAN hacia los compañeros

| Desde | Destino | Resultado esperado |
|---|---|---|
| Cualquier VLAN | Internet por HTTPS (TCP 443) y DNS | Sale por E2 → E5 → E3 con su dirección real |
| Cualquier VLAN | Internet por HTTP (TCP 80) | Lo intercepta Squid en E2, que aplica su lista según la VLAN de origen |
| ADMIN, USUARIOS y SERVIDORES | WEB01 de la DMZ, `172.16.10.10:8081` | `200` |
| GESTIÓN | WEB01 de la DMZ | Sin respuesta: R1 solo le deja salir por 53, 80 y 443 |
| VLAN ADMIN | Portal de Squid, `192.168.84.1:8080` | `200`. A USUARIOS y SERVIDORES el propio portal les responde `403`; GESTIÓN no llega (R1) |

Por cuál ISP de E3 sale cada VLAN se ve con `grupal/isp-activo.sh` (dentro de R1) y `grupal/isp-panel.py` (en el host).
