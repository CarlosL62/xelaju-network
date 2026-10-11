# 02 — Runbook individual (host Debian)

Pasos para levantar la LAN completa del Estudiante 1 en el host Debian, con lo que debe verse en cada uno. Todo se ejecuta desde la carpeta del componente (`E1 - LAN/` de este repositorio) salvo que se indique "dentro de la VM".

Tiempo total aproximado: 30–40 minutos con buena conexión (5–15 min la imagen base, 3–10 min Zabbix, menos de un minuto cada uno de los demás equipos), más unos 10 min por cada escritorio.

> **Estado de este runbook.** Ejecutado completo el 3 de octubre de 2026 en el host Debian: imagen base, las 10 VMs con su `aplicar.sh`, DHCP real, Zabbix y la matriz de pruebas, sin fallos. Lo que hubo que corregir por el camino está en `07-problemas-y-soluciones.md`.

## 0. Orden y dependencias

```
host ──► imagen base ──► R1-LAN ──► SW-CORE01 ──► ZBX-SRV01, SRV-INTRA01, PC-MGMT01
                                         └──► SW-ACC01 ──► PC-ADMIN01, PC-USER01, PC-USER02, PC-INTRUSO
```

R1 va primero porque da la salida a Internet (modo individual) que necesitan los demás para instalar paquetes. Cada switch va antes que los equipos conectados a él.

## 1. Preparar el host

```bash
./lab/lab.sh dependencias          # dice qué falta
sudo apt install tmux wireshark    # lo que falte según la orden anterior
./lab/lab.sh verificar
```

Debe verse: `KVM accesible`, `QEMU 10.x con -netdev dgram`, `topologia.conf coherente (10 VMs, 9 cables)`, `puertos UDP de los cables libres` y al final `Host listo`.

- En este host faltaban solo `tmux` y `wireshark` (opcionales: sin `tmux` no funciona `lab.sh tmux`; Wireshark es para abrir las capturas).
- Si `verificar` dice "sin acceso a /dev/kvm": `sudo usermod -aG kvm $USER` y volver a iniciar sesión.
- RAM: el laboratorio completo usa 7936 MB. Si no alcanza, se arranca por grupos.
- Disco: hacen falta unos 10 GB libres (base ~2 GB, Zabbix ~2 GB, cada PC con escritorio ~2 GB).

## 2. Validar sin VMs (2 minutos, opcional pero recomendable)

```bash
./pruebas/validar-estatico.sh
./pruebas/simular-lan.sh
```

Debe terminar con `Validación estática correcta` y `Matriz: 61 PASS, 0 FAIL, 2 omitidas`.

## 3. Imagen base

```bash
./lab/lab.sh base
```

1. Descarga el instalador de red de Debian 13 (unos 53 MB) y verifica su SHA256.
2. Pide dos veces la **contraseña del usuario `xelaju`** (será la de todas las VMs). Solo se guarda su hash.
3. Instala Debian de forma desatendida. Se ve la consola del instalador en modo texto; no hay que tocar nada. Tarda 5–20 minutos según la conexión y la VM se apaga sola.

Si se lanza sin terminal (por ejemplo desde otro programa), no puede pedir la contraseña: genera una al azar, la guarda en `lab/base/.secreto-xelaju` (solo para el dueño, fuera de git) y deja la consola del instalador en `lab/run/base.consola.log`. Se cambia después, con las VMs encendidas, con `./lab/lab.sh clave`.

El sistema se instala en inglés con teclado latinoamericano: por consola serie el instalador solo ofrece "C" e "English" (ver `07-problemas-y-soluciones.md`).

Debe terminar con: `imagen base lista: .../lab/imagenes/debian13-base.qcow2`.

Si termina con "no llegó a la marca final": revisar `lab/run/base.consola.log`. Si el instalador sí terminó, `./lab/lab.sh base --aceptar`; para repetir, `./lab/lab.sh base --rehacer`. Respaldo manual: instalar Debian 13 desde la ISO netinst sobre `lab/imagenes/debian13-base.qcow2` (usuario `xelaju`, sin escritorio, con servidor SSH) y ejecutar dentro `lab/base/post-base.sh` como root.

## 4. Discos de las VMs

```bash
./lab/lab.sh crear todas
./lab/lab.sh estado
```

Cada disco es una capa delgada sobre la imagen base: se crean al instante y ocupan casi nada hasta que se usan.

## 5. Patrón que se repite en cada nodo

```bash
./lab/lab.sh iniciar <vm>
./lab/lab.sh consola <vm>          # Enter para ver el login; Ctrl+] para salir
```

Dentro de la VM, entrar como `xelaju` y ejecutar:

```bash
sudo /mnt/proyecto/nodos/<vm>/aplicar.sh
```

`aplicar.sh` es idempotente: se puede repetir y sirve para restaurar el nodo. Guarda copia de lo que cambia en `/var/backups/xelaju/`.

Lo mismo sin entrar a la consola, desde el host:

```bash
./lab/lab.sh aplicar <vm>          # ejecuta nodos/<vm>/aplicar.sh dentro de la VM y muestra su salida
```

La salida queda además en `evidencias/consola/<vm>-aplicar.log`. Para la defensa conviene haberlo hecho al menos una vez por consola, que es como se pide trabajar en la infraestructura.

Si `/mnt/proyecto` aparece vacío: `sudo mount -t 9p -o trans=virtio,version=9p2000.L,ro proyecto /mnt/proyecto`.

## 6. R1-LAN

```bash
./lab/lab.sh iniciar r1-lan
./lab/lab.sh consola r1-lan
sudo /mnt/proyecto/nodos/r1-lan/aplicar.sh
```

Al final muestra `r1-estado`. Debe verse:

- Interfaces: `trunk0` UP sin IP; `trunk0.10` a `trunk0.40` con 192.168.10.1 … 192.168.40.1; `tmp-nat` con 10.0.2.15/24.
- Rutas: `default via 10.0.2.2 dev tmp-nat` y una ruta conectada por cada VLAN.
- `net.ipv4.ip_forward = 1`.
- ACL: tabla con las cadenas `entrada`, `reenvio`, `desde_admin`, `desde_users`… y `desde_perimetro`.
- Servicios: `nftables`, `isc-dhcp-server`, `rsyslog`, `ssh` y `zabbix-agent2` en `active`.
- DHCP: `servicio isc-dhcp-server: active`, `escucha en: INTERFACESv4="trunk0.20"`, 3 equipos registrados.

Comprobaciones:

```bash
sudo r1-modo estado            # Modo actual de R1-LAN: individual ... NAT en R1: si
sudo xelaju-dhcp verificar     # todo [ OK ]
curl -sI http://deb.debian.org | head -1     # HTTP/1.1 200 OK  (R1 tiene Internet)
```

Desde el host también se puede entrar por SSH: `ssh -p 2221 xelaju@127.0.0.1`.

## 7. Núcleo: SW-CORE01, servidores y gestión

```bash
./lab/lab.sh iniciar sw-core01
./lab/lab.sh consola sw-core01
sudo /mnt/proyecto/nodos/sw-core01/aplicar.sh
```

Debe mostrar `show vlan brief` con `30 SERVIDORES activa p2, p3` y `40 GESTION activa p4`, y `show interfaces trunk` con `p0 ... 10,20,30,40` y `p1 ... 10,20,40`. Comprobar: `ping -c 2 192.168.40.1` responde.

```bash
./lab/lab.sh iniciar servidores pc-mgmt01
```

- **ZBX-SRV01** (`sudo /mnt/proyecto/nodos/zbx-srv01/aplicar.sh`): instala MariaDB, Zabbix y Apache (5–10 min; la importación del esquema no muestra nada durante unos minutos). Debe mostrar `zabbix-server escuchando en TCP 10051`, `desde 127.0.0.1: HTTP 200` y `desde 192.168.30.10 (fuera de ADMIN): HTTP 403`. Al final ejecuta `monitoreo.py`, que arma el monitoreo por la API (grupos, autorregistro, equipos por ping, items de R1, el equipo del Multi-WAN y los dos dashboards) y debe terminar con `monitoreo configurado`.
- **SRV-INTRA01** (`.../srv-intra01/aplicar.sh`): `HTTP -> 200` y `HTTPS -> 200`.
- **PC-MGMT01** (`.../pc-mgmt01/aplicar.sh`): `lan0` con 192.168.40.10/24.

## 8. Acceso: SW-ACC01 y clientes

```bash
./lab/lab.sh iniciar sw-acc01
./lab/lab.sh consola sw-acc01
sudo /mnt/proyecto/nodos/sw-acc01/aplicar.sh
```

Debe mostrar `10 ADMIN activa p1`, `20 USUARIOS activa p2, p3, p4` y la troncal `p0 ... 10,20,40`.

```bash
./lab/lab.sh iniciar clientes
```

Se abren dos ventanas (PC-ADMIN01 y PC-USER01); los demás son solo consola.

| VM | Orden dentro de la VM | Debe verse |
|---|---|---|
| pc-admin01 | `sudo /mnt/proyecto/nodos/pc-admin01/aplicar.sh` | `lan0 ... 192.168.10.50/24` |
| pc-admin01 | `sudo /mnt/proyecto/nodos/pc-admin01/escritorio.sh` | escritorio XFCE tras unos 10 min |
| pc-user01 | `sudo /mnt/proyecto/nodos/pc-user01/aplicar.sh` | `DHCP: recibio 192.168.20.10` |
| pc-user01 | `sudo /mnt/proyecto/nodos/pc-user01/escritorio.sh` | escritorio XFCE |
| pc-user02 | `sudo /mnt/proyecto/nodos/pc-user02/aplicar.sh` | `DHCP: recibio 192.168.20.11` |
| pc-intruso | `sudo /mnt/proyecto/nodos/pc-intruso/aplicar.sh` | `lan0` UP sin dirección |

En R1 se ve la concesión: `sudo xelaju-dhcp log` muestra DHCPDISCOVER, DHCPOFFER, DHCPREQUEST y DHCPACK de `aa:bb:cc:dd:ee:01`.

## 9. Zabbix desde la web

En PC-ADMIN01, Firefox: `http://192.168.30.10/zabbix` (usuario `Admin`, contraseña `zabbix`). El monitoreo ya está armado por `monitoreo.py`; desde la web queda:

1. Cambiar la contraseña de `Admin` (`03-zabbix.md`, sección 3).
2. Revisar *Monitoring → Hosts* (R1-LAN, los dos switches y SRV-INTRA01 registrados solos; los PC por ping) y los dashboards "LAN - Estudiante 1" y "Multi-WAN - Estudiante 3".

`03-zabbix.md` explica además cómo se haría cada paso a mano desde la web, para poder defenderlo.

Si cambias la contraseña de `Admin` y más adelante repites `monitoreo.py`, pásale la nueva: `sudo /mnt/proyecto/nodos/zbx-srv01/monitoreo.py --clave <clave>`.

## 10. Pruebas y evidencias

```bash
./lab/lab.sh probar                        # todos los perfiles; resumen en evidencias/pruebas/
./lab/lab.sh capturar sw-core01 p0 30      # troncal etiquetada -> evidencias/pcap/
```

Lista completa de evidencias y demostraciones (alta y baja del intruso, DORA frente a DISCOVER sin respuesta) en `04-pruebas-y-evidencias.md`.

## 11. Uso diario

| Para | Orden |
|---|---|
| Ver qué está encendido | `./lab/lab.sh estado` |
| Apagar todo ordenadamente | `./lab/lab.sh detener todas` |
| Encender por partes | `./lab/lab.sh iniciar infra`, luego `servidores`, luego `clientes` |
| Todas las consolas a la vez | `./lab/lab.sh tmux` |
| Ejecutar algo en una VM sin entrar | `./lab/lab.sh exec r1-lan r1-estado` |
| Restaurar un nodo | repetir su `aplicar.sh` |
| Empezar de cero un nodo | `./lab/lab.sh destruir <vm>` y `./lab/lab.sh crear <vm>` |

Tras un reinicio, cada nodo vuelve solo a su configuración: los nombres de interfaz (archivos `.link`), la red (`/etc/network/interfaces`), las ACL (`nftables.service`), el DHCP y los switches (`xelaju-switch.service`) son persistentes.

## Si algo falla

| Síntoma | Qué revisar |
|---|---|
| `aplicar.sh`: "sin salida a Internet" | En R1: `sudo r1-modo estado` (debe ser individual) y `curl -sI http://deb.debian.org`. En el host: que haya Internet. En SW-CORE01: `switch-mostrar vlan` |
| Un equipo no llega a su puerta de enlace | En su switch: `switch-mostrar puertos` (¿"conectado"?) y `switch-mostrar mac` (¿aparece su MAC en la VLAN correcta?) |
| PC-USER01 no recibe IP | En R1: `sudo xelaju-dhcp verificar` y `sudo xelaju-dhcp log`. ¿SW-ACC01 configurado? |
| La consola no muestra nada | Pulsar Enter. Mirar `lab/run/<vm>.consola.log` |
| `lab.sh exec` dice que el agente no responde | La VM aún arranca, o falta `qemu-guest-agent` (viene en la imagen base) |
| La VM no arranca | `cat lab/run/<vm>.qemu.log` |
| Después de aplicar, el nombre de las interfaces no cambió | `ip -br link`; comparar las MAC con `lab/topologia.conf` |
