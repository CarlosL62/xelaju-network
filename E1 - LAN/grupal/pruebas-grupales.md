# Pruebas grupales — lo que le toca demostrar a la LAN (Estudiante 1)

Complementa a `CHECKLIST-INTEGRACION.md`. Cada tabla dice desde qué equipo se prueba, el comando y el resultado esperado. Los mismos casos están en formato ejecutable en `matriz-grupal.conf`.

Los casos de esta página ya se ensayaron con `./pruebas/simular-lan.sh grupal`: R1, los switches y ZBX con sus archivos reales, y dobles de prueba de E2, E5, E3 y E4 con las direcciones de `core/ADDRESSING.yaml`. Contra los equipos reales se probó por primera vez el 4 de octubre de 2026; qué pasó y qué quedó pendiente está en `docs/04-pruebas-y-evidencias.md`, sección 1.

Los comandos "desde R1" o "desde PC-…" se ejecutan dentro de esa VM, no en la terminal del host.

La columna **Decide** dice quién toma la decisión: **R1** (ACL de la LAN) o **E5** (firewall perimetral). R1 no repite la política VPN (ADR-0002).

## Cómo ejecutar

- **Equipos de la LAN** (perfiles `g-admin`, `g-users`, `g-mgmt`, `g-zbx`), dentro de la VM:
  ```bash
  sudo XJ_MATRIZ=/mnt/proyecto/grupal/matriz-grupal.conf /mnt/proyecto/pruebas/probar.sh g-admin
  ```
- **Equipos de los compañeros**: a mano, con los comandos de las tablas.

"Sin respuesta" significa que el comando agota el tiempo. Si lo descartó R1, queda una línea `ACL-DENY` en `/var/log/xelaju/acl-lan.log`.

## 1. Enlace con Squid y rutas

| Desde | Comando | Esperado | Decide |
|---|---|---|---|
| E2 | `ping -c 3 192.168.84.2` | Responde | R1 |
| E2 | `nc -zv -w 4 192.168.84.2 22` | Sin respuesta (nadie administra R1 desde fuera) | R1 |
| E5 | `ping -c 3 192.168.84.2` | Responde | R1 |
| R1 | `sudo traceroute -T -p 443 -s 192.168.20.1 -n 1.1.1.1` | Saltos 192.168.84.1 (E2), 192.168.82.1 (E5) y 192.168.81.1 (E3): el camino completo. Con `ping` no se puede: E5 no reenvía ICMP | E2, E5, E3 |

## 2. Desde la LAN hacia el grupo

| Desde | Comando | Esperado | Decide |
|---|---|---|---|
| PC-ADMIN01 | `ping -c 3 192.168.84.1` | Responde | R1 |
| PC-ADMIN01, PC-USER01 | `curl -sS -m 6 -o /dev/null -w '%{http_code}\n' https://1.1.1.1` | `301`: HTTPS directo por E5 y E3, con la IP real del equipo | R1 y E5 |
| R1 | el mismo `curl` con `--interface 192.168.20.1` | `301`: salida con origen en la VLAN 20 | E5 |
| PC-ADMIN01, PC-USER01, ZBX-SRV01 | `curl -m 6 -o /dev/null -w '%{http_code}\n' http://172.16.10.10:8081/` | 200: la LAN ve WEB01 por E2 → E5 → E4 | R1 y E5 |
| PC-USER01 | `nc -zv -w 4 172.16.10.10 22` | Sin respuesta: hacia la DMZ solo el puerto de WEB01 | E5 |
| PC-MGMT01 | el mismo `curl` a WEB01 | Sin respuesta: GESTIÓN solo sale a 53, 80 y 443 | R1 |

## 3. VPN-ADMIN (10.200.10.0/24)

| Comando en el cliente VPN | Esperado | Decide |
|---|---|---|
| `ping -c 3 192.168.10.50` | Responde (ADMIN) | E5 |
| `nc -zv -w 4 192.168.20.10 22` | Conecta (USUARIOS) | E5 |
| `ping -c 3 192.168.30.10` | Responde (Zabbix, solo ping) | E5 |
| `curl -m 6 -o /dev/null -w '%{http_code}\n' http://192.168.30.20/` | 200 (Intranet) | E5 |
| `nc -zv -w 4 192.168.40.2 22` | Conecta (SSH de SW-CORE01) | E5 |
| `curl -m 6 http://192.168.30.10/zabbix/` | Sin respuesta: la web de Zabbix es solo para la VLAN ADMIN | R1 |

## 4. VPN-USERS (10.200.20.0/24)

| Comando en el cliente VPN | Esperado | Decide |
|---|---|---|
| `ping -c 3 192.168.20.10` | Responde (USUARIOS) | E5 |
| `curl -m 6 -o /dev/null -w '%{http_code}\n' http://192.168.30.20/` | 200 | E5 |
| `curl -k -m 6 -o /dev/null -w '%{http_code}\n' https://192.168.30.20/` | 200 | E5 |
| `nc -zv -w 4 192.168.30.20 22` | Sin respuesta | E5 |
| `ping -c 2 192.168.10.50` | Sin respuesta (ADMIN) | E5 |
| `nc -zv -w 4 192.168.40.2 22` | Sin respuesta (GESTIÓN) | E5 |
| `curl -m 6 http://192.168.30.10/zabbix/` | Sin respuesta | E5 y R1 |

La lista de servicios de la VLAN 30 para VPN-USERS (aquí, solo la Intranet por 80/443) es una propuesta de E1 pendiente de acordar con E5.

## 5. DMZ (172.16.10.0/24)

| Comando en WEB01 | Esperado | Decide |
|---|---|---|
| `ping -c 2 192.168.10.50` | Sin respuesta | E5 y R1 |
| `ping -c 2 192.168.20.10` | Sin respuesta | E5 y R1 |
| `curl -m 6 http://192.168.30.20/` | Sin respuesta | E5 y R1 |

## 6. Monitoreo (agentes de Zabbix de los compañeros)

| Desde | Comando | Esperado | Decide |
|---|---|---|---|
| E3 (192.168.81.1) | `nc -zv -w 4 192.168.30.10 10051` | Conecta: el agente puede entregar métricas | E5 y R1 |
| E4 (192.168.83.2) | `nc -zv -w 4 192.168.30.10 10051` | Conecta | E5 y R1 |
| E2 (192.168.84.1) | `nc -zv -w 4 192.168.30.10 10051` | Conecta | R1 |
| E3 | `curl -m 6 http://192.168.30.10/zabbix/` | Sin respuesta | E5 y R1 |
| E3, E2 | `ping -c 2 192.168.10.50` | Sin respuesta | E5 y R1 |

## 7. Sin NAT en R1

| Dónde mirar | Qué debe verse |
|---|---|
| Registro de acceso de Squid mientras PC-USER01 navega | Origen `192.168.20.10`, no `192.168.84.2` |
| En E3, contadores de las políticas por origen | Coinciden con 192.168.20.10, .11 y .12 |
| En R1: `sudo nft list ruleset \| grep -c 'type nat'` | `0` |
| En R1: `sudo r1-modo estado` | "NAT en R1: no" |

## 8. La frontera E1/E5, demostrada

`simular-lan.sh grupal` termina con unas comprobaciones "Sin E5…": vacía las reglas del doble del firewall y repite pruebas. Sirve para explicar qué protege cada uno:

- Aun sin E5, R1 niega DMZ → LAN, la web de Zabbix desde fuera y todo lo que no sea VPN o monitoreo.
- Sin E5, un cliente VPN-USERS **sí** llegaría a la VLAN ADMIN: esa política es de E5 y R1 no la repite.

## Evidencias que conviene guardar

| Evidencia | Cómo |
|---|---|
| Estado de R1 en modo grupal | `sudo r1-estado` (captura de pantalla) |
| Bloqueos con origen y destino | `sudo tail -20 /var/log/xelaju/acl-lan.log` |
| Conexiones VPN que R1 dejó pasar | `sudo nft list chain inet xelaju desde_perimetro` (contador de `ACL-ALLOW VPN->LAN`) |
| Tráfico del enlace hacia Squid | En el host: `./lab/lab.sh capturar r1-lan up-squid 30` y abrir el `.pcap` en Wireshark |
| Resultado de los perfiles `g-*` | Se guardan solos en `evidencias/pruebas/` |
| Equipo `Router-MultiWAN-E3` y su dashboard en Zabbix | Captura desde PC-ADMIN01 |
