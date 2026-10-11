# Checklist de integración grupal — Estudiante 1

Orden pensado para detectar pronto el problema más probable: cableado, luego rutas, luego políticas. Cada paso dice cómo se comprueba. Las direcciones son las de `core/ADDRESSING.yaml` (en esta entrega, `tablas/direccionamiento.csv`).

Camino real del tráfico (ADR-0001 y ADR-0002):

```
LAN ── R1 ── E2 (Squid) ── E5 (Firewall) ──┬── E3 (Multi-WAN) ── Internet
                                           └── E4 (VPN y DMZ)
```

## 0. Antes de reunirse (en casa)

- [ ] Repositorio al día (`git pull --rebase`) y `./pruebas/validar-estatico.sh`: "Validación estática correcta".
- [ ] `./pruebas/simular-lan.sh grupal` termina sin FAIL.
- [ ] El laboratorio individual funciona: `./lab/lab.sh probar` sin fallos (ver `docs/02-runbook-individual.md`).
- [ ] Llevar: un cable de red y este repositorio.

## 1. Conexión física y modo grupal

- [ ] Decidir el medio con E2: una tarjeta de red con cable, o VXLAN por Wi-Fi.
- [ ] En el host:
  ```bash
  sudo ./lab/grupal/uplinks-host.sh up --squid enp7s0
  ```
  Comprobar: `sudo ./lab/grupal/uplinks-host.sh estado` muestra el bridge con su TAP y su tarjeta.
- [ ] Reiniciar R1 para que tome el TAP:
  ```bash
  ./lab/lab.sh detener r1-lan && ./lab/lab.sh iniciar r1-lan
  ```
- [ ] Dentro de R1-LAN: `sudo r1-modo grupal`. Comprobar: `up-squid` con 192.168.84.2/30, ruta por defecto vía 192.168.84.1, "NAT en R1: no".

A partir de aquí, todas las pruebas se lanzan **dentro de R1 o de una VM**. Desde la terminal del host no sirven: el host no tiene dirección en el enlace, solo hace de puente, y sus ping se van por su propia conexión.

## 2. Vecino directo (E2)

- [ ] Desde R1: `ping -c 3 192.168.84.1`.
- [ ] Desde E2: `ping -c 3 192.168.84.2`.

Si falla: `ip neigh` en R1 (¿aparece la MAC del vecino o queda `INCOMPLETE`?), `sudo ./lab/grupal/uplinks-host.sh estado`, y que E2 tenga la dirección de su lado del enlace. Para ver qué envía el equipo del otro extremo sin tener acceso a él, grabar el enlace desde el host con `./lab/lab.sh capturar r1-lan up-squid 12` y leer la captura con `tcpdump -e -n -r <archivo>`: si solo llegan peticiones DHCP, esa tarjeta aún no tiene dirección fija.

## 3. Rutas, salto por salto

R1 no hace NAT: cada equipo del camino necesita **una ruta por VLAN** de vuelta (`routing_plan` de `core/`).

- [ ] E2 reenvía IP (`sysctl net.ipv4.ip_forward` = 1) y tiene las cuatro rutas vía 192.168.84.2.
- [ ] E5 tiene las cuatro rutas vía E2; E3, vía E5.
- [ ] Desde PC-ADMIN01: `ping -c 3 192.168.84.1` (E2). Si no responde, a E2 le faltan las rutas a las VLAN.
- [ ] Desde R1: `sudo traceroute -T -p 443 -s 192.168.20.1 -n 1.1.1.1`. Deben aparecer, en orden, 192.168.84.1 (E2), 192.168.82.1 (E5) y 192.168.81.1 (E3). El primer salto que no responda señala el equipo donde se corta.
- [ ] Desde E5: `ping -c 3 192.168.84.2` (R1 responde a los enlaces de tránsito).

Más allá de E2 no sirve `ping`: el firewall de E5 no reenvía ICMP ni contesta a la LAN. Por eso el camino se comprueba con un traceroute por TCP al puerto 443, que sí está permitido.

Si el ping sale pero no vuelve: en el equipo del compañero, `tcpdump -ni <interfaz> icmp` muestra la petición con origen 192.168.10.50; falta su ruta de vuelta.

## 4. Flujo A — navegación desde la LAN

- [ ] PC-USER01: `curl -sS -m 6 -o /dev/null -w '%{http_code}\n' https://1.1.1.1` → `301`. HTTPS no lo intercepta Squid: sale directo por E5 y E3.
- [ ] PC-USER01: abre un dominio permitido por HTTP → carga (lo sirve Squid).
- [ ] PC-USER01: abre un dominio de `users_blacklist` → Squid lo bloquea.
- [ ] PC-ADMIN01: abre un dominio de `admins_blacklist` → bloqueado; uno que solo está en la lista de usuarios → carga.
- [ ] En el registro de Squid, las peticiones aparecen con **192.168.20.10** y **192.168.10.50** (prueba de que R1 no hace NAT).
- [ ] PC-INTRUSO con IP puesta a mano: no navega (bloqueado en R1 antes de llegar a Squid).

Las listas negras solo actúan sobre HTTP (puerto 80). Si el puerto 80 se rechaza al instante, comprobar desde una VM que E2 tiene abierto su puerto de intercepción: `nc -zv -w 3 192.168.84.1 3129`.
- [ ] En E3, las políticas por origen se aplican a 192.168.20.10, .11 y .12.

## 5. Flujo B — acceso por VPN

Seguir `pruebas-grupales.md`, secciones VPN-ADMIN y VPN-USERS. Quién decide cada cosa:

- [ ] Cliente VPN-ADMIN: llega a ADMIN, USUARIOS, servidores y GESTIÓN (lo autoriza **E5**, R1 lo deja pasar); **no** abre la web de Zabbix (lo niega **R1**).
- [ ] Cliente VPN-USERS: llega a la VLAN de usuarios y a la Intranet por 80/443; nada más (lo decide **E5**).
- [ ] En R1, `sudo nft list chain inet xelaju desde_perimetro`: la regla `ACL-ALLOW VPN->LAN` cuenta paquetes.
- [ ] WEB01 (DMZ) no puede iniciar conexión hacia la LAN (lo niegan **E5** y **R1**).

## 6. Flujo C — la LAN llega a la DMZ

- [ ] Desde PC-ADMIN01 y PC-USER01: `curl -m 6 -o /dev/null -w '%{http_code}\n' http://172.16.10.10:8081/` → 200. Camino: R1 → E2 → E5 → E4.
- [ ] Desde PC-MGMT01 (GESTIÓN; solo tiene consola): el mismo `curl` → `000`, sin respuesta. Es lo esperado: R1 solo deja salir a GESTIÓN por 53, 80 y 443, y WEB01 escucha en el 8081. Desde el host:
  ```bash
  ./lab/lab.sh exec pc-mgmt01 'curl -m 6 -o /dev/null -w "%{http_code}\n" http://172.16.10.10:8081/'
  ./lab/lab.sh exec r1-lan 'grep -a "r1-lan kernel: ACL-DENY MGM[T]" /var/log/xelaju/acl-lan.log | tail -2'
  ```
  La segunda orden muestra el bloqueo en R1 (`ACL-DENY MGMT->?`, origen `192.168.40.10`, destino `172.16.10.10`).

## 7. Monitoreo del Multi-WAN

- [ ] En E3: `sudo ./scripts/setup_zabbix.sh` (genera las métricas con `zabbix_agent_multiwan.sh --generate`, las copia al agente y lo reinicia). Así lo dejó funcionando E3 el 10 de octubre.
- [ ] Desde E3: `nc -zv -w 4 192.168.30.10 10051` conecta.
- [ ] En Zabbix (desde PC-ADMIN01): el equipo `Router-MultiWAN-E3` del grupo `XelajuNetwork/Multi-WAN` recibe datos (*Monitoring → Latest data*; en la web aparece con su nombre visible, `Multi-WAN (Estudiante 3)`).
- [ ] El dashboard "Multi-WAN - Estudiante 3" muestra el tráfico de entrada y de salida de ISP1 e ISP2.
- [ ] Dentro de R1: `sudo /mnt/proyecto/grupal/isp-activo.sh` muestra por cuál ISP sale cada VLAN y lo registra en `evidencias/consola/isp-activo-AAAAMMDD.log`. Con los dos ISP arriba el estado es `NORMAL`; al desconectar uno debe pasar a `SOLO-ISP1` o `SOLO-ISP2` (failover de E3) y volver a `NORMAL` al reconectarlo.

Si no llegan datos: en R1, `sudo grep -a 10051 /var/log/xelaju/acl-lan.log` (¿se está bloqueando?, ¿con qué IP de origen llega?); en ZBX-SRV01, `sudo nft list table inet xelaju_zbx` y `sudo grep -i 'Router-MultiWAN' /var/log/zabbix/zabbix_server.log`. Si R1 no ve llegar nada, lo está parando E5.

## 8. Cierre

- [ ] Lo acordado que cambie un dato compartido se anota en las tablas del grupo (`tablas/`) y se ajusta en E1: `lab/topologia.conf` y los `define` de `00-definiciones.nft`.
- [ ] Guardar evidencias: `sudo r1-estado` en R1, capturas de pantalla, `./lab/lab.sh capturar r1-lan up-squid 30`.
- [ ] Para volver al laboratorio individual: en R1 `sudo r1-modo individual`; en el host `sudo ./lab/grupal/uplinks-host.sh down` y reiniciar R1.

## Decisiones tomadas en la integración

| Fecha | Decisión | Con quién | Cambio aplicado en |
|---|---|---|---|
| | | | |
| | | | |
| | | | |
