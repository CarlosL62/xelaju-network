# 06 — Scripts del proyecto

Qué hace cada script, cómo se usa y cuáles son sus partes. Todos están comentados en el propio archivo; aquí está el mapa para explicarlos.

Convenciones comunes:

- `set -euo pipefail`: el script se detiene ante el primer error (`-e`), ante una variable sin definir (`-u`) o si falla cualquier orden de una tubería (`pipefail`).
- **Idempotentes**: se pueden ejecutar varias veces; siempre dejan el mismo resultado. Por eso sirven para restaurar.
- Mensajes sin tildes, para que se lean bien en cualquier consola serie.
- Antes de aplicar una configuración de servicio, se **valida** (`nft -c`, `dhcpd -t`, `apache2ctl configtest`, `nginx -t`).

## 1. En el host

### `lab/lab.sh` — orquestador del laboratorio

| Orden | Qué hace |
|---|---|
| `dependencias [--instalar]` | Lista (o instala con sudo) los paquetes del host |
| `verificar` | KVM, versión de QEMU, RAM, disco, puertos libres, coherencia de `topologia.conf` |
| `base [--rehacer\|--aceptar]` | Crea la imagen base con una instalación desatendida |
| `crear <objetivo>` | Disco de cada VM (capa delgada sobre la base) |
| `iniciar` / `detener [--forzar]` / `destruir [-s]` | Ciclo de vida |
| `estado`, `cables` | Tablas de VMs y de cables con sus puertos UDP |
| `consola <vm>`, `tmux` | Consola serie de una VM o de todas |
| `exec <vm> <orden>` | Ejecuta una orden como root dentro de la VM, sin red |
| `aplicar <vm> [guion]` | Ejecuta `nodos/<vm>/aplicar.sh` (u otro guion del nodo) dentro de la VM y sigue su salida; la guarda en `evidencias/consola/` |
| `clave` | Cambia la contraseña del usuario `xelaju` en todas las VMs encendidas (viaja solo su hash, por el agente del invitado) |
| `capturar <vm> <interfaz> [s] [archivo]` | Graba un cable a `.pcap` |
| `probar [perfil...]` | Corre la matriz de pruebas en los clientes y junta los resultados |
| `qemu <vm>` | Muestra la línea de comandos de QEMU de esa VM |

`<objetivo>` es una VM, un grupo (`infra`, `servidores`, `clientes`) o `todas`.

Partes del script:

1. **Lectura de `topologia.conf`** con `sed` (quita comentarios) y `awk` (filtra por la primera palabra): `opcion`, `lista_vms`, `campo_vm`, `lista_nics`, `objetivos`.
2. **`puertos_cable`**: el primer `nic` que nombra un cable es el extremo A (puerto 40000+2N) y el segundo el B (40000+2N+1); cada uno envía al puerto del otro.
3. **`args_red`**: un `-netdev` y un `-device virtio-net-pci` por tarjeta. `cable` → `dgram` (UDP por 127.0.0.1); `nat` → `user` con `hostfwd`; `tap` → la interfaz TAP si existe y, si no, un puerto sin cable; `aislado` → puerto sin cable. Un puerto sin cable (`sin_cable`) es un hub interno de QEMU con dos puertos: el de la tarjeta y un sumidero que descarta lo que recibe; con un solo puerto el hub no aceptaría tramas y la tarjeta se quedaría con la cola llena.
4. **`args_vm`**: máquina `q35` con KVM, disco virtio, consola serie en un socket (con copia en `run/<vm>.consola.log`), socket QMP, canal del agente del invitado y dos carpetas compartidas 9p (el repositorio en solo lectura y `evidencias/` con escritura).
5. **`viva`**: una VM está encendida si su PID existe y es el QEMU de esa VM.
6. **`cmd_base`**: descarga `linux` e `initrd.gz` del instalador de red y los compara con `SHA256SUMS`; pide la contraseña y calcula su hash con `openssl passwd -6`; mete `preseed.cfg` y `post-base.sh` al final del initrd (un initrd puede ser varios archivos `cpio` concatenados); arranca el instalador con `-kernel/-initrd` y espera a que se apague; busca la marca `XELAJU_POST_BASE=OK` en el registro de la consola. Sin terminal no puede pedir la contraseña: genera una al azar en `lab/base/.secreto-xelaju` (0600, fuera de git) y deja la consola del instalador en un socket y en un registro.
7. **`cmd_aplicar`**: espera a que el agente del invitado responda, lanza el guion dentro de la VM desligado del agente (`setsid nohup`, para que no tenga límite de tiempo) con la salida hacia la carpeta compartida de evidencias, y la sigue con `tail -f` hasta que aparece el archivo con el código de salida.

No usa root: KVM se abre con el grupo `kvm` (o ACL) y la red son sockets UDP locales.

### `lab/qemuctl.py` — control de las VMs por sus sockets

Dos protocolos JSON, un mensaje por línea:

- **QMP** (`<vm>.qmp`): habla con QEMU. Órdenes: `estado`, `apagar` (botón de encendido ACPI), `salir`, `hmp`, `capturar` (crea un objeto `filter-dump` sobre un cable, espera y lo elimina).
- **QGA** (`<vm>.qga`): habla con `qemu-guest-agent` dentro de la VM. Órdenes: `agente` (comprueba que responde) y `exec` (`guest-exec` + `guest-exec-status`, con la salida codificada en base64).

Clases: `Canal` (socket y lectura por líneas), `Qmp` (saludo, `qmp_capabilities`, ignora los eventos) y `Qga` (se sincroniza con `guest-sync` antes de cada sesión). Solo biblioteca estándar.

### `lab/base/preseed.cfg.plantilla` y `lab/base/post-base.sh`

El **preseed** responde por adelantado las preguntas del instalador de Debian: idioma inglés (`en_US.UTF-8`; por consola serie el instalador no ofrece español) con los locales `es_ES` y `es_GT` añadidos, teclado `latam`, zona `America/Guatemala`, usuario `xelaju` sin cuenta root (administra con `sudo`), todo el disco con el esquema `atomic`, tareas `standard` y `ssh-server` más las herramientas de red, y apagado al terminar. `@@HASH@@` se sustituye por el hash de la contraseña.

**`post-base.sh`** se ejecuta una vez dentro del sistema recién instalado: cambia `dhcpcd` por `dhclient`; agrega el repositorio de Zabbix e instala `zabbix-agent2` apagado; declara las carpetas compartidas en `/etc/fstab`; configura GRUB y el kernel para la consola serie; desactiva las tareas automáticas de apt. Nunca devuelve error (detendría al instalador): lo que no pueda hacer lo anota como aviso.

### `lab/grupal/uplinks-host.sh` — enlace físico con Squid en la parte grupal (sudo)

R1 tiene un solo enlace con el grupo (`up-squid`). `up` crea una interfaz TAP y un bridge, y une el bridge al medio elegido: una tarjeta física (`--squid`) o un túnel VXLAN sobre otra red (`--vxlan`, con `--squid-remoto` y, si hace falta, `--vni`). Retira la tarjeta de NetworkManager, y si `br_netfilter` está activo agrega una regla que acepta el tráfico de ese bridge. Guarda lo hecho en `/run/xelaju-uplinks.estado` para que `down` lo deshaga exactamente.

### `pruebas/validar-estatico.sh`, `pruebas/consistencia.py`, `pruebas/simular-lan.sh`

- **`validar-estatico.sh`**: `bash -n` de todos los scripts; `py_compile`; reglas de R1 (dos modos) y de ZBX con `nft -c` y cargadas de verdad dentro de `unshare -rn` (un namespace de red donde el usuario es root, sin tocar el cortafuegos del host); `consistencia.py`; `xelaju-dhcp verificar`.
- **`consistencia.py`**: lee `topologia.conf` y comprueba que digan lo mismo el CSV, los `interfaces`, las tablas de puertos (según lo que hay al otro lado de cada cable), las definiciones de nftables, `dhcpd.conf`, `hosts.xelaju`, las matrices de pruebas y este directorio de documentación. Su sección 8 compara todo eso con `core/ADDRESSING.yaml`, la fuente de verdad del grupo (VLAN y puertas de enlace, enlace con E2 y ruta por defecto, IP de Zabbix, redes VPN, enlaces de tránsito, DMZ). El YAML se lee con expresiones regulares para no depender de bibliotecas; la función `redes` resuelve los `define` de nftables que nombran a otros (`$RED_ADMIN`…) y devuelve el conjunto de redes. Si el grupo cambia un dato compartido, aquí se ve qué hay que tocar en E1. Esa sección necesita el `core/ADDRESSING.yaml` del repositorio de trabajo del grupo: donde no está, como en esta entrega, el script lo indica y la omite.
- **`simular-lan.sh`**: crea un namespace por VM y un par veth por cable (con las MAC reales), aplica los scripts de switch y las reglas de R1 y ZBX tal cual están en el repositorio, levanta servicios de prueba y ejecuta `probar.sh` con la matriz. En modo `grupal` arma además **dobles de prueba** de los equipos de los compañeros, con las direcciones y rutas de `core/`: `e2` (reenvía entre sus dos enlaces), `e5` (política por omisión `drop` y las reglas propuestas en el ADR-0002), `e3` (único NAT, y un conjunto de nftables que anota cada IP de origen que ve antes de traducirla), `e4` con dos clientes VPN y WEB01, y un "ISP" con el sitio de Internet. Funciones: `vecino` (namespace unido a un enlace de R1), `enlace` (cable entre dos dobles) y `rutas` (una ruta por red). Tras la matriz grupal, vacía las reglas del doble de E5 y repite unas pruebas (`llega` / `no_llega`): lo que siga bloqueado lo bloquea R1 por sí solo.

## 2. Comunes a los nodos

### `nodos/_comun/comun.sh` — biblioteca de los `aplicar.sh`

| Función | Qué hace |
|---|---|
| `xj_requerir_root` | Exige root y que el repositorio esté montado |
| `xj_instalar` | Copia un archivo con permisos y dueño; si el destino existía y era distinto, guarda copia fechada en `/var/backups/xelaju/` |
| `xj_instalar_arbol` | Copia todo `rootfs/` sobre `/` conservando rutas (`usr/local/sbin` como ejecutable) |
| `xj_conf` | Deja una línea `Clave=valor` en un archivo de configuración (reemplaza, descomenta o agrega) |
| `xj_identidad` | Nombre del equipo, `machine-id` y llaves SSH propios, zona horaria, `/etc/hosts` |
| `xj_interfaces_por_mac` | Por cada tarjeta del nodo: archivo `.link` (MAC → nombre) y renombrado inmediato |
| `xj_red_detener` / `xj_red_iniciar` | Baja y sube las interfaces con ifupdown |
| `xj_resolv` | DNS fijos |
| `xj_base` | Lo anterior en orden, más los ajustes comunes del kernel |
| `xj_paquetes` | Instala solo lo que falte; si no hay Internet, se detiene con una explicación |
| `xj_sin_arranque` | Instala sin que el servicio arranque con la configuración de fábrica (`policy-rc.d`) |
| `xj_agente_zabbix` | Configura y enciende el agente en modo activo |
| `xj_switch`, `xj_cliente` | Pasos completos de un switch y de un PC |

### `nodos/_comun/switch/` — el switch

- **`switch-aplicar`**: crea `br0` con filtrado de VLAN, sin VLAN por omisión y sin STP; recorre `puertos.conf` (saca el puerto del bridge para empezar limpio, lo vuelve a meter y le asigna sus VLAN según sea `access`, `trunk`, `span` o `apagado`); fija la MAC del bridge; crea `br0.40` con la IP de gestión y la ruta por defecto; activa los espejos.
- **`switch-mostrar`**: `vlan`, `trunk`, `mac`, `puertos`, `config`, `todo`. Las tres primeras leen el estado real del kernel (`bridge vlan show`, `bridge fdb show`).
- **`switch-span`**: `activar <origen> <destino>`, `desactivar <origen>`, `estado`. Usa `tc` con `clsact` y `mirred`.
- **`xelaju-switch.service`**: unidad `oneshot` que ejecuta `switch-aplicar` en cada arranque.

### `nodos/_comun/escritorio.sh`

Instala XFCE, LightDM y Firefox ESR en un PC cliente y pone el arranque gráfico. Solo se usa en PC-ADMIN01 y PC-USER01.

## 3. R1-LAN

### `nodos/r1-lan/aplicar.sh`

1. Guarda el modo actual (individual por omisión).
2. `xj_base`: identidad y nombres de interfaz (`trunk0`, `up-squid`, `tmp-nat`).
3. Copia `rootfs/` sobre `/`.
4. Activa el reenvío y levanta la troncal y las subinterfaces.
5. `r1-modo <modo>`: enlaces de salida y reglas. Después habilita e inicia `nftables.service`, que carga las mismas reglas en cada arranque.
6. Instala `isc-dhcp-server` y `conntrack` sin arrancarlos, y vuelve a copiar `rootfs/`.
7. Registros: `/var/log/xelaju` y reinicio de rsyslog.
8. `xelaju-dhcp aplicar` y `verificar`.
9. Agente de Zabbix; el usuario `zabbix` entra al grupo `adm` para leer los registros.
10. `r1-estado`.

### `r1-modo individual|grupal|estado`

Cambia dos enlaces simbólicos y recarga. Orden de `cambiar`: (1) apunta el enlace de reglas al modo nuevo y lo comprueba con `nft -c` (si falla, deshace y no toca la red); (2) baja los enlaces del modo anterior; (3) apunta el enlace de red y levanta los del modo nuevo; (4) carga las reglas y vacía la tabla de conexiones (`conntrack -F`) para olvidar traducciones del modo anterior.

### `r1-estado`

Resumen para capturas: interfaces, VLAN de cada subinterfaz, rutas, reenvío, paquetes permitidos y bloqueados por cadena (lo calcula con `awk` sobre `nft list table`), DHCP, últimos eventos y servicios.

### `xelaju-dhcp listar|alta|baja|aplicar|verificar|log`

| Función | Qué hace |
|---|---|
| `filas` | Lee el CSV: quita espacios y retornos de carro, pasa la MAC a minúsculas, ignora cabecera, vacías y comentarios |
| `validar` | Cabecera exacta; nombre con letras, números y guion; MAC con formato válido, que no sea de grupo (bit menos significativo del primer octeto) ni todo ceros; IP en 192.168.20.10–250; sin nombre, MAC ni IP repetidos |
| `generar` | Escribe `reservas-vlan20.conf` (un `host` por fila) y `10-registrados.nft` (el conjunto MAC . IP) |
| `aplicar` | Valida, genera, comprueba con `dhcpd -t` y `nft -c` (si fallan restaura lo anterior), reinicia dhcpd y actualiza el conjunto en memoria |
| `actualizar_conjunto` | `flush set` + `add element` en una sola transacción: no se pierden los contadores de las demás reglas |
| `cmd_alta` | Normaliza la MAC, elige la primera IP libre si no se indica, añade la fila; si la validación falla, deja el CSV como estaba |
| `cmd_baja` | Quita la fila, aplica y borra las conexiones activas de esa IP (`conntrack -D`) |
| `cmd_verificar` | CSV, archivos generados, conjunto en memoria, servicio activo, interfaz de escucha y ausencia de `range` |
| `auditar` | Añade fecha, usuario y acción a `/var/log/xelaju/registro-dhcp.log` |

Qué parte del DHCP está escrita a mano, qué genera este script y cómo se registra un equipo sin él: `01-diseno-red.md`, secciones 7.1 y 7.2.

### `xelaju-metrica`

Imprime un número para Zabbix: equipos registrados (filas del CSV) o líneas del registro actual que contienen `DHCPACK`, `no free leases` o `ACL-DENY`.

## 4. Servidores y clientes

### `nodos/zbx-srv01/aplicar.sh`

Red; repositorio y paquetes de Zabbix; locales; base de datos (contraseña generada una vez y guardada en `/root/zabbix-db.txt`); importación del esquema (con marca para no repetirla; si quedó a medias, vacía y repite); `DBPassword` en el servidor; `zabbix.conf.php`; restricción de Apache; nftables; arranque de servicios con espera al puerto 10051 (y `AllowUnsupportedDBVersions` si el registro lo pide); agente; comprobación (200 desde 127.0.0.1 y 403 desde la IP del propio servidor); y por último `monitoreo.py`.

### `nodos/zbx-srv01/monitoreo.py` — el monitoreo, por la API de Zabbix

Hace por consola lo que `03-zabbix.md` describe para la web. La API es JSON-RPC sobre HTTP: la clase `Zabbix` envía `{"method": ..., "params": ...}` y devuelve `result` o lanza el `error`; la sesión viaja en la cabecera `Authorization: Bearer`. Solo biblioteca estándar.

| Función | Qué crea (si no existe) |
|---|---|
| `grupo`, `plantilla` | Los grupos `XelajuNetwork/LAN` y `XelajuNetwork/Multi-WAN`; localiza las plantillas `Linux by Zabbix agent active` e `ICMP Ping` |
| `accion_autorregistro` | La acción que da de alta a los agentes cuyo `HostMetadata` contiene `xelaju-lan` |
| `equipos_ping`, `equipo_ping` | Un equipo por cada PC de `lab/topologia.conf` con dirección, vigilado por ping |
| `items_r1` | Los cuatro items propios de R1-LAN (DHCP y ACL) |
| `equipo_multiwan`, `items_multiwan` | El equipo `Router-MultiWAN-E3` y sus ocho items, con el preprocesado que convierte contadores en bits/s y paquetes/s |
| `dashboard_lan`, `dashboard_multiwan` | Los dos dashboards; si ya existen, los reescribe |

Termina con 0 si todo quedó creado, 2 si falta lo que depende de que R1-LAN se haya registrado (se repite más tarde) y 1 si hubo un error. `--esperar N` aguarda hasta N segundos a que R1-LAN aparezca; `--clave` es la contraseña de `Admin`.

### `nodos/srv-intra01/aplicar.sh`

Red, `nginx` y `ssl-cert`, sitio de la Intranet en 80 y 443, comprobación con `curl`, agente de Zabbix.

### `nodos/sw-*/aplicar.sh` y `nodos/pc-*/aplicar.sh`

Envolturas cortas: cargan `comun.sh` y llaman a `xj_switch` o `xj_cliente`. Los de PC-USER01 y PC-USER02 comprueban además que la IP recibida es la reservada.

## 5. Pruebas

### `pruebas/probar.sh <perfil>`

Lee de `matriz.conf` los casos del perfil y ejecuta una **sonda** por caso; cada sonda imprime una palabra:

| Sonda | Cómo decide |
|---|---|
| `sonda_ip` | Primera IPv4 de `lan0` |
| `sonda_ping` | `ping -c 2 -W 2`: OK o BLOQUEADO |
| `sonda_tcp` | `timeout 4 bash -c "exec 3<>/dev/tcp/IP/PUERTO"`: 0 = OK, 124 (tiempo agotado) = BLOQUEADO, otro = RECHAZADO |
| `sonda_http` | `curl` con 6 s de límite: código HTTP, RECHAZADO (código de salida 7) o BLOQUEADO |
| `sonda_internet` | `curl` a una página conocida: OK si responde 2xx o 3xx |
| `sonda_dhcp renovar` | `ifdown` + `ifup` y devuelve la IP obtenida |
| `sonda_dhcp pedir` | `dhclient -1` con 10 s de límite: SIN-OFERTA si nadie contesta |
| `sonda_estatica`, `sonda_limpiar` | Pone y quita una IP a mano (perfil `intruso`) |

Compara lo obtenido con lo esperado, imprime la tabla y copia el resultado a `/mnt/evidencias/pruebas/`. Código de salida 0 si no hay ningún FAIL.

### `grupal/isp-activo.sh` — por cuál ISP sale cada tráfico (dentro de R1, modo grupal)

Muestra una tabla cada 10 s y agrega una línea por ciclo a `evidencias/consola/isp-activo-AAAAMMDD.log`: por cada VLAN de origen y por TCP 443 y UDP 53, el ISP de E3 por el que salió (ISP1 = Wi-Fi, ISP2 = celular) y si una conexión real fue y volvió.

| Función | Qué hace |
|---|---|
| `salto_de_e3` | Traceroute por TCP 443 para saber en qué salto responde E3 (`192.168.81.1`) |
| `sonda_salida` | Un paquete con el TTL justo para caducar en el salto siguiente a E3: quien avisa es la puerta de enlace del ISP que E3 eligió para esa conexión |
| `sonda_extremo` | Conexión real con ese origen: `nc` al puerto TCP o una consulta `dig` por UDP 53 |
| `evaluar` | Aprende las dos puertas de las clases de referencia (`REF_ISP1`, `REF_ISP2`: salida fija en `policies.txt` de E3) y decide el estado: `NORMAL`, `SOLO-ISP1`/`SOLO-ISP2` (failover), `PARCIAL` (una referencia sin respuesta o sin ruta en E3), `SIN-SALIDA`… Cada cambio queda como `EVENTO` en el registro |
| `mostrar` | La tabla, con el reparto de los últimos 10 ciclos (ahí se ve el balanceo), y la línea del registro |

### `grupal/isp-panel.py` — el registro del ISP como panel en vivo (en el host)

No mide nada ni entra a las VMs: lee el registro que escribe `isp-activo.sh` y lo redibuja cada segundo en la terminal del host, con colores. Muestra el estado y su significado, las puertas de cada ISP, una tabla por VLAN y tipo de tráfico (ISP actual, si la conexión real funcionó y una barra con los últimos 20 ciclos) y los últimos cambios de estado. Si el monitor se detiene o deja de escribir, lo avisa. `--una-vez` lo dibuja una sola vez; `--sin-color` y `--ascii` son para terminales limitadas. Solo biblioteca estándar.

Sobre `isp-activo.sh`: las direcciones de los ISP no se escriben en ningún archivo: son de E3 y la del celular cambia al reconectarlo. `consistencia.py` comprueba que las dos referencias sigan teniendo salida fija en las políticas de E3. El HTTP no se puede seguir así porque sale desde Squid (E2).
