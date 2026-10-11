# 07 — Problemas encontrados y soluciones

Tres partes: lo que ocurrió al preparar y validar el repositorio, lo que **puede ocurrir** al ejecutar el laboratorio (con su solución preparada) y lo que ocurrió de verdad al levantarlo y al adaptarlo al repositorio del grupo.

## 1. Problemas reales al preparar el repositorio

| # | Problema | Causa | Solución aplicada |
|---|---|---|---|
| 1 | La URL del paquete `zabbix-release` devolvía 404 | Zabbix 7.0 conserva la ruta antigua (`/zabbix/7.0/debian/pool/...`); la ruta con `/release/` es de 7.2 en adelante | Se corrigió la URL en `post-base.sh` y `comun.sh`; `consistencia.py` vigila que ambas sean iguales |
| 2 | `nft`, `bridge` y `tc` "no instalados" en el host | Están en `/usr/sbin`, que no está en el PATH de un usuario normal de Debian | Todos los scripts exportan un PATH que incluye `/usr/sbin` |
| 3 | `switch-mostrar vlan` no listaba los puertos de acceso | En awk, asignar `$1 = ""` no renumera los campos: se leía la columna equivocada de `bridge vlan show` | Se distinguen las líneas con nombre de puerto de las de continuación; comprobado en el ensayo |
| 4 | Una captura con `tcpdump ... icmp` en el puerto espejo no veía nada | En una troncal (y en el SPAN) la etiqueta 802.1Q va dentro de la trama; el filtro `icmp` busca IPv4 justo tras la cabecera Ethernet | Usar `vlan and icmp`. Anotado en `04-pruebas-y-evidencias.md` |
| 5 | La tabla MAC salía con el total al principio | El total pasaba por el mismo `sort` que las filas | Se ordena la tabla y el total se imprime después |
| 6 | `/sys/class/net` mostraba las interfaces del host dentro de un namespace de pruebas | `sysfs` pertenece al namespace de red de quien lo montó | En las pruebas se monta un `sysfs` propio; `ip netns exec` ya lo hace solo |
| 7 | `xj_sin_arranque` podía dejar `/usr/sbin/policy-rc.d` si la instalación fallaba | El script terminaba antes de borrar el archivo; después ningún servicio arrancaría al instalarse | La orden se ejecuta en un subshell y el archivo se borra siempre |
| 8 | Con `set -o pipefail`, `orden \| grep -q` puede dar error aunque encuentre | `grep -q` cierra la tubería al primer acierto y la orden anterior muere por SIGPIPE | Se evitó ese patrón en `lab.sh` (comparaciones con `[[ ]]` o `awk`) |
| 9 | `qemuctl.py exec --limite N` ignoraba el límite | Todo lo que sigue al socket se toma como parte de la orden a ejecutar | `--limite` va antes del socket; documentado en el propio script |

## 2. Problemas previstos y cómo están resueltos

### Imagen base e instalador

| Problema | Solución |
|---|---|
| El instalador se detiene con una pregunta | Se ve en la consola; responder a mano. `post-base.sh` nunca devuelve error para no provocarlo |
| `lab.sh base` termina sin la marca final | `lab/run/base.consola.log`; `base --aceptar` si la instalación terminó, `base --rehacer` para repetir |
| `post-base.sh` no pudo instalar el agente de Zabbix | Cada `aplicar.sh` lo reintenta cuando el nodo tiene Internet |
| No hay Internet en el host | La base y los `aplicar.sh` que instalan paquetes lo necesitan. Los switches y los PC sin escritorio no instalan nada |
| Falta espacio en disco | Solo hay unos 14 GB libres. Instalar el escritorio en un solo PC o borrar VMs que no se usen (`lab.sh destruir`) |
| Falta RAM | Arrancar por grupos; bajar la RAM de una VM en `lab/topologia.conf` |

### Debian 13 "trixie"

| Problema | Solución |
|---|---|
| `isc-dhcp-server` está marcado como obsoleto | Sigue en el repositorio (4.4.3-P1-8) y el enunciado exige el servicio nativo, no Kea. Si desapareciera, el mismo diseño funciona en Debian 12 cambiando solo la versión del instalador |
| El cliente DHCP por omisión es `dhcpcd` | La base instala `isc-dhcp-client` y quita `dhcpcd-base`: así `ifup` y las demostraciones usan `dhclient` |
| Al instalar `isc-dhcp-server` el servicio intenta arrancar con la configuración de fábrica y falla | `xj_sin_arranque` (policy-rc.d) evita ese arranque; después se copian nuestros archivos y se inicia |
| El paquete podría reescribir `/etc/default/isc-dhcp-server` | `aplicar.sh` vuelve a copiar el árbol `rootfs/` después de instalar |
| `rsyslog` no viene instalado | Está en la lista de paquetes de la base; sin él no habría `acl-lan.log` ni `dhcpd.log` |
| Zabbix no arranca: "unsupported MariaDB version" | `zbx-srv01/aplicar.sh` lo detecta en el registro y activa `AllowUnsupportedDBVersions=1` |
| Parámetros repetidos en `zabbix_agent2.conf` | No se añade un segundo archivo con `Server=`: se edita la línea existente (`xj_conf`) |

### Red y nombres de interfaz

| Problema | Solución |
|---|---|
| Los nombres `enp0sN` dependen del orden de las tarjetas | Nombres fijos por MAC con archivos `.link` de systemd, generados desde `topologia.conf` |
| Un `.link` por MAC también coincide con las VLAN y el bridge (heredan la MAC) | `Type=ether` en la sección `[Match]`: solo tarjetas reales |
| Los `.link` no se aplican al arrancar | El initramfs lleva una copia: `comun.sh` ejecuta `update-initramfs -u` al crearlos |
| Las VMs clonadas comparten `machine-id` y llaves SSH | `xj_identidad` los regenera una vez por nodo |
| La consola serie se llena de mensajes del kernel (cada paquete registrado por las ACL) | `kernel.printk = 3 4 1 3` en todos los nodos |
| `/mnt/proyecto` vacío | Se monta al primer acceso; si no, `sudo mount -t 9p -o trans=virtio,version=9p2000.L,ro proyecto /mnt/proyecto` |
| `ping` a Internet falla en modo individual | El NAT de QEMU en modo usuario no siempre deja pasar ICMP. Para probar Internet se usa `curl` (así lo hace `probar.sh`) |
| El ping a otra IP de R1 falla desde una VLAN | Es intencional: cada VLAN solo puede hacer ping a su propia puerta de enlace (cadena `entrada`) |

### ACL y DHCP

| Problema | Solución |
|---|---|
| Se bloqueó tráfico hacia el propio router creyendo que era entre redes (o al revés) | Lección del Proyecto 1: `entrada` (INPUT) es lo dirigido a R1; `reenvio` (FORWARD) es lo que lo atraviesa. Están separadas y comentadas en `30-acl.nft` |
| dhcpd responde aunque el firewall bloquee el puerto 67 | dhcpd lee las tramas en capa 2, antes del firewall. Por eso se limita con `INTERFACESv4="trunk0.20"` y no con reglas |
| Tras dar de baja un equipo, sus conexiones abiertas siguen funcionando | Las ACL son con estado. `xelaju-dhcp baja` borra los estados de esa IP con `conntrack -D` |
| Un usuario se pone una IP estática para saltarse el DHCP | El binding MAC·IP de las ACL lo bloquea; el caso está en la matriz (perfil `intruso`) |
| Alguien clona la MAC **y** la IP de un equipo registrado | Las ACL no lo distinguen. Mejora posible: seguridad de puerto en el switch de acceso (una MAC fija por puerto) |
| Probar la suplantación con la IP de PC-USER01 deja a ese PC sin red un rato | El router aprende la MAC del intruso para esa IP. La prueba usa la reserva de PC-USER03 (192.168.20.12), que no está encendido |
| Una avalancha de paquetes denegados llena el registro | Las reglas registran sin límite para que cada bloqueo de las pruebas quede anotado. Mejora posible: `limit rate` en una regla aparte, antes del `drop` |
| El CSV se editó a mano con un error | `xelaju-dhcp aplicar` valida antes de tocar nada y, si dhcpd o nftables rechazan el resultado, restaura lo anterior |

### Parte grupal

| Problema | Solución |
|---|---|
| El bridge del host no pasa tráfico | Con `br_netfilter` cargado, las tramas pasan por iptables FORWARD. `uplinks-host.sh` agrega la regla de aceptación para sus bridges |
| NetworkManager quita la tarjeta del bridge o le pide IP | `uplinks-host.sh` la marca como no gestionada y la devuelve en `down` |
| R1 no ve los TAP | QEMU los toma al arrancar: reiniciar la VM después de `uplinks-host.sh up` |
| El ping sale hacia un compañero y no vuelve | A ese equipo (o a uno intermedio) le falta la ruta de vuelta a la VLAN de origen: R1 no hace NAT y el grupo usa una ruta por VLAN. `grupal/CHECKLIST-INTEGRACION.md`, paso 3 |
| Los clientes VPN o el agente de E3 no llegan a la LAN | Mirar primero en R1: `sudo grep -a -E 'PERIMETRO|SPOOF' /var/log/xelaju/acl-lan.log`. Si R1 no registra nada, el paquete no llegó: lo para E5 o falta una ruta en E2 |
| Por VXLAN las páginas grandes no cargan | MTU 1450: descomentar `mtu 1450` en `/etc/network/modos/grupal`; R1 ya ajusta el MSS de TCP (`ajuste_mss`) |
| El grupo cambia una dirección en `core/` | `./pruebas/validar-estatico.sh` falla en la sección 8 de `consistencia.py` y dice qué dato difiere. Se corrige en `lab/topologia.conf` y en `00-definiciones.nft` |

## 3. Problemas durante la ejecución real

Lo que apareció al levantar el laboratorio y al adaptarlo al repositorio del grupo. Seguir anotando aquí lo que salga en la integración.

| Fecha | Dónde | Síntoma | Causa | Solución |
|---|---|---|---|---|
| 3-oct | Diseño | El diseño inicial tenía un segundo enlace de R1 hacia VPN/DMZ, repetía en R1 la política VPN, resumía las VLAN en un solo prefijo, esperaba otro nombre de equipo para el Multi-WAN en Zabbix y bloqueaba un "portal de Squid" con IP y puerto supuestos | Se diseñó antes de conocer las decisiones del grupo, que ya había acordado otra cosa (ADR-0001, ADR-0002, agente de E3) | Se adaptó E1 a `core/` y a los ADR: un solo enlace, cadena `desde_perimetro`, una ruta por VLAN, `Router-MultiWAN-E3`, sin reglas sobre datos que nadie ha publicado. `consistencia.py` ahora compara con `core/` para que no vuelva a pasar |
| 3-oct | `lab.sh base` | La instalación desatendida se quedó detenida en "Select a language", sin haber escrito nada en el disco | El preseed pedía el idioma `es`. Por consola serie el instalador no puede dibujar todos los alfabetos y solo ofrece "C" e "English": la respuesta del preseed no estaba entre las opciones y la pregunta volvió a hacerse | Preseed con `language en`, `country GT`, `locale en_US.UTF-8` y los locales `es_ES`/`es_GT` como adicionales; el teclado sigue siendo `latam`. La instalación terminó sola en unos 5 minutos |
| 3-oct | R1-LAN | `r1-estado` mostraba el servicio `nftables` como `inactive` aunque las reglas estaban cargadas | Las reglas las carga `r1-modo` con `nft -f`; `aplicar.sh` solo habilitaba el servicio para el siguiente arranque | `aplicar.sh` hace además `systemctl start nftables` (carga el mismo archivo en una transacción) |
| 3-oct | ZBX-SRV01 | Durante `aplicar.sh`, el paso de `monitoreo.py` no mostraba nada hasta terminar | Python guarda la salida en un búfer cuando no escribe a una terminal (aquí, a un registro) | Se llama con `python3 -u` |
| 3-oct | SW-CORE01 (y `lab.sh`) | El puerto espejo `p5` no transmitía: `tc` contaba las copias, pero la tarjeta marcaba 0 paquetes enviados, miles en cola y *tx timeouts*; `lab.sh capturar sw-core01 p5` grababa un archivo vacío. El ensayo con namespaces no lo veía (ahí el puerto es un `dummy`) | En QEMU un puerto "aislado" era un hub interno con un solo puerto. Un hub así no acepta tramas (no tiene a quién entregarlas), QEMU deja de vaciar la cola de la tarjeta y la VM se queda esperando | `lab.sh` (`sin_cable`) añade al hub un segundo puerto "sumidero" sin nadie detrás, que recibe y descarta. Tras reiniciar la VM: 0 pérdidas, y la captura del espejo trae la troncal con sus etiquetas. Lo mismo aplica a `up-squid` de R1 cuando no hay TAP |
| 3-oct | `lab.sh capturar` | Dos capturas simultáneas en la misma VM: la segunda fallaba | El socket QMP de cada VM atiende a un cliente a la vez | Capturar un puerto por VM cada vez (en VMs distintas sí se puede a la vez) |
| 3-oct | Zabbix | El dashboard de la LAN mostraba vacías las gráficas de tráfico por VLAN | Los items `Interface …` no existen hasta que la plantilla descubre las interfaces, y de fábrica lo hace una vez por hora | `monitoreo.py` deja ese descubrimiento en 5 minutos |
| 4-oct | Host | Con el cable ya enchufado, R1 no llegaba a E2 | La tarjeta `enp7s0` del host tenía una dirección de otra práctica (`10.0.0.2/30`, en `/etc/network/interfaces` del host) y no existía el puente hacia la VM | `sudo ./lab/grupal/uplinks-host.sh up --squid enp7s0`, reiniciar la VM de R1 y `r1-modo grupal`. El script limpia esa dirección mientras dura el enlace; si el host se reinicia hay que repetir `up` |
| 4-oct | Host | `ping 192.168.84.1` desde la terminal del host no responde | El host no tiene dirección en el enlace: solo conmuta tramas entre el cable y la VM. Ese ping se va por el Wi-Fi | Las pruebas se hacen dentro de R1 o de una VM (`./lab/lab.sh exec r1-lan 'ping -c 3 192.168.84.1'`) |
| 4-oct | Enlace E1–E2 | R1 preguntaba por ARP quién tiene `192.168.84.1` y nadie contestaba | La tarjeta de E2 en ese cable aún no tenía la dirección: seguía pidiendo DHCP. Se vio grabando el enlace con `./lab/lab.sh capturar r1-lan up-squid 12` y leyendo la captura con `tcpdump -r` | E2 configuró la dirección del enlace y las rutas de vuelta a las VLAN. La captura del enlace permite saber qué pasa en el otro extremo sin tener acceso a ese equipo |
| 4-oct | Cadena E2–E5 | El traceroute se quedaba en el salto 1 y HTTPS no salía | E2 aún no tenía levantado su lado hacia E5 (`192.168.82.2` no respondía) | Lo levantó E2. Después: HTTPS `301` y traceroute con E2, E5 y E3 |
| 4-oct | E5 | Desde la LAN no responde el ping a E5 ni a E3 | No es un fallo: su firewall no reenvía ICMP y solo contesta ping a sus vecinos directos | Probar el camino con `traceroute -T -p 443 -s <IP de la VLAN> 1.1.1.1` |
| 4-oct | E2 | El HTTP (puerto 80) de la LAN se rechaza al instante | En E2 el puerto 3128 de Squid está abierto pero el 3129, al que su nftables redirige el puerto 80, está cerrado | **Resuelto por E2** la noche del 4-oct: el 3129 responde, Squid intercepta el HTTP de las cuatro VLAN y los casos `internet` de la matriz pasan (63 PASS en modo grupal) |
| 4-oct | DMZ | LAN → WEB01 (`172.16.10.10:8081`) falla a los 3 s; `probar.sh` lo marca RECHAZADO | No es un rechazo de WEB01. Capturado en `up-squid`: quien responde es E5 (`192.168.82.1`) con ICMP "host unreachable", 3 s después del primer SYN. Deducción de E1: E5 no logra resolver el siguiente salto hacia la DMZ. A las 23:05 seguía igual, aunque E5 anotó a las 21:56 que E4 (`192.168.83.2`) salía a Internet por su firewall: el enlace E5–E4 funcionaba entonces | **Resuelto por E4/E5** antes de las 23:23: WEB01 responde `200` a las VLAN 10, 20 y 30 (qué se cambió no se ve desde E1). `curl` termina con el mismo código 7 si lo rechazan y si no hay camino al equipo: por eso la matriz dice RECHAZADO |
| 4-oct | DNS | En una de las pruebas, DNS por UDP a `1.1.1.1` no respondía (sí a `8.8.8.8`, y sí por TCP) | La salida en ese momento era por el ISP móvil de E3; minutos después, saliendo por el otro ISP, respondió | Fuera de E1. El DHCP entrega primero `8.8.8.8`. Después, `isp-activo.sh` mostró que solo el DNS de la VLAN 20 tiene salida fija (ISP2); el de las VLAN 10, 30 y 40 va balanceado entre los dos ISP |
| 4-oct | PC-ADMIN01 | En Firefox, `google.com` cargó a las 19:12, dejó de cargar entre las 19:13 y las 19:48 y a las 19:59 volvía a cargar | Sin determinar desde E1. En esos minutos R1 no registró ninguna denegación para `192.168.10.50` y la configuración local no cambió. El historial del navegador sugiere que `google.com` respondía su redirección y lo que fallaba era `www.google.com`. Sospechas sin confirmar: el DNS por UDP saliendo por el ISP2, o las conexiones TCP 443 por el ISP1 | Se creó `grupal/isp-activo.sh` para dejar registrado por cuál ISP sale cada VLAN y si la conexión va y vuelve. Si se repite: `traceroute -T -p 443 -n 1.1.1.1` y `dig @8.8.8.8` desde el PC en ese momento |
| 4-oct | E5 | QUIC (UDP 443) no sale: Firefox envió 74 paquetes y no volvió ninguno | El firewall de E5 solo deja salir de la LAN TCP 443, DNS y NTP | No es un fallo: el navegador pasa a TCP y la página carga igual |
| 4-oct | `isp-activo.sh` | Con varias sondas seguidas por clase, muchas quedaban sin respuesta | Los routers de los ISP limitan los avisos ICMP de "TTL agotado": una ráfaga corta y después uno por segundo | Una sonda por clase, pausa entre clases y un reintento solo cuando la conexión real sí funcionó |
| 4-oct | Camino hacia Internet | Entre las 21:33 y las 21:36 fallaron de forma intermitente conexiones TCP 443 (primero las que salen por ISP1, luego las de ISP2). A las 21:37 E2 dejó de responder: R1 pregunta por ARP por `192.168.84.1` y no llega ninguna trama, aunque el cable tiene portadora | Fuera de E1 y sin determinar desde aquí | Anotado en `evidencias/consola/integracion-grupal-squid-dmz-isp.log`, punto 6. E2 volvió a responder antes de las 22:35, tras un cambio en su equipo |
| 4-oct | `isp-activo.sh` | En el failover real marcó `NORMAL` durante un ciclo (22:42:41 y 22:47:32) con media LAN todavía sin salida | Una referencia ya salía por su ISP y para la otra E3 contestaba "sin ruta": las dos respuestas eran distintas y el script lo tomaba por dos ISP activos | Corregido: ese caso ahora es `PARCIAL`. Comprobado con sondas simuladas |
| 4-oct | Multi-WAN | Duda: ¿hay DNS por UDP cuando solo queda el ISP2 (el celular)? | — | En esta prueba, sí: con todo por el ISP2 hubo 815 conexiones correctas y 1 fallida, incluidas las de UDP 53 |
| 10-oct | Host | Tras reiniciar el host, R1 no llegaba a E2 aunque `r1-modo grupal` mostraba `up-squid` arriba con su dirección | El puente y el TAP del host no sobreviven al reinicio, y R1 arrancó con esa tarjeta aislada | `sudo ./lab/grupal/uplinks-host.sh up --squid enp7s0`, reiniciar la VM de R1 y `r1-modo grupal`. Para saberlo desde el host: `ip link show tap-r1-squid` |
| 10-oct | Zabbix | Con los datos de E3 ya llegando, las gráficas del dashboard "Multi-WAN - Estudiante 3" seguían vacías; los valores sueltos y *Latest data* sí se veían | `monitoreo.py` ponía en las gráficas el nombre del agente (`Router-MultiWAN-E3`) y el widget elige el equipo por su nombre visible (`Multi-WAN (Estudiante 3)`). En la LAN no se notó porque ahí los dos nombres coinciden | Constante `NOMBRE_WAN` en `monitoreo.py`, usada al crear el equipo y en las gráficas; se repitió el script, que reescribe el dashboard |
| 10-oct | R1-LAN | `grep` sobre `acl-lan.log` decía "binary file matches" y solo mostraba líneas de días anteriores | El host se apagó sin cerrar las VMs y el registro quedó con 288 bytes nulos en medio; `grep` lo toma por un archivo binario | Usar `grep -a` (o `tail`, al que no le afecta). Los comandos de esta documentación ya llevan `-a`; el contador de Zabbix no se ve afectado |
| 3-oct | Zabbix | Duda: ¿se registran solos los agentes que arrancaron antes de existir la acción de autorregistro? | — | Sí: R1, los switches y la Intranet aparecieron a los pocos segundos de crear la acción, sin reiniciar nada (cada agente vuelve a preguntar al servidor qué debe medir) |
| | | | | |
| | | | | |
