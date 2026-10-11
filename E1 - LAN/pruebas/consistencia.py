#!/usr/bin/env python3
"""consistencia.py - cruza los datos del repositorio para que no se contradigan.

lab/topologia.conf es la fuente de verdad (VMs, MAC, cables, direcciones).
Este script comprueba que todo lo demas dice lo mismo:

  1. topologia.conf     nombres y MAC unicos, cada cable con dos extremos
  2. usuarios.csv       las MAC/IP de los PC con DHCP estan registradas; el intruso no
  3. interfaces         cada nodo configura la direccion y la puerta de enlace de la topologia
  4. switches           puertos.conf coincide con lo que hay al otro lado de cada cable
  5. nftables           redes y equipos de las ACL = direccionamiento real
  6. DHCP               dhcpd.conf, la interfaz de escucha y los archivos generados
  7. varios             /etc/hosts, matriz de pruebas, URL de Zabbix, documentacion
  8. core/              lo anterior coincide con core/ADDRESSING.yaml, la fuente de
                        verdad del grupo (VLAN, enlace con E2, Zabbix, VPN, DMZ)

Uso:  python3 pruebas/consistencia.py        (codigo de salida 0 si todo coincide)
Solo biblioteca estandar: el YAML de core/ se lee con expresiones regulares.
"""

import ipaddress
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
R1 = REPO / "nodos/r1-lan/rootfs"
fallos = 0


def ok(texto):
    print(f"  [ OK ] {texto}")


def fallo(texto):
    global fallos
    fallos += 1
    print(f"  [FALLO] {texto}")


def comprobar(condicion, texto, detalle=""):
    if condicion:
        ok(texto)
    else:
        fallo(f"{texto}{' -> ' + detalle if detalle else ''}")
    return condicion


def lineas(ruta):
    """Lineas utiles de un archivo: sin comentarios (#...) ni lineas vacias."""
    salida = []
    for linea in Path(ruta).read_text().splitlines():
        linea = linea.split("#", 1)[0].strip()
        if linea:
            salida.append(linea)
    return salida


def texto(ruta):
    return Path(ruta).read_text()


# ----------------------------------------------------------------------------
# 1. topologia.conf
# ----------------------------------------------------------------------------
print("1. lab/topologia.conf")
vms, nics, ips, opciones = {}, [], [], {}
for l in lineas(REPO / "lab/topologia.conf"):
    c = l.split()
    if c[0] == "vm":
        vms[c[1]] = {"ram": int(c[2]), "cpus": int(c[3]), "pantalla": c[4], "grupo": c[5]}
    elif c[0] == "nic":
        nics.append({"vm": c[1], "if": c[2], "mac": c[3], "con": c[4]})
    elif c[0] == "ip":
        ips.append({"vm": c[1], "if": c[2], "dir": c[3], "gw": c[4], "metodo": c[5], "modo": c[6]})
    elif c[0] == "opcion":
        opciones[c[1]] = c[2]

macs = [n["mac"] for n in nics]
comprobar(len(set(macs)) == len(macs), "todas las MAC son distintas")
comprobar(all(re.fullmatch(r"([0-9a-f]{2}:){5}[0-9a-f]{2}", m) for m in macs), "formato de las MAC")
comprobar(all(int(m[:2], 16) & 1 == 0 for m in macs), "ninguna MAC es de grupo (bit de multidifusion)")
comprobar(all(n["vm"] in vms for n in nics), "cada nic pertenece a una VM declarada")
comprobar(all(i["vm"] in vms for i in ips), "cada ip pertenece a una VM declarada")

cables = {}
for n in nics:
    if n["con"].startswith("cable:"):
        cables.setdefault(n["con"][6:], []).append(n)
malos = [c for c, extremos in cables.items() if len(extremos) != 2]
comprobar(not malos, f"los {len(cables)} cables tienen exactamente dos extremos", ", ".join(malos))
base = int(opciones.get("udp_base", 40000))
puertos = [base + 2 * int(c[1:]) + k for c in cables for k in (0, 1)]
comprobar(len(set(puertos)) == len(puertos) and max(puertos) < 65536, "puertos UDP de los cables sin choques")
ok(f"RAM total declarada: {sum(v['ram'] for v in vms.values())} MB en {len(vms)} VMs")


def nic_de(vm, ifn):
    return next(n for n in nics if n["vm"] == vm and n["if"] == ifn)


def otro_extremo(nic):
    """La nic que esta al otro lado del cable, o None si no es un cable."""
    if not nic["con"].startswith("cable:"):
        return None
    return next(n for n in cables[nic["con"][6:]] if n is not nic)


def ip_de(vm, ifn="lan0"):
    return next((i for i in ips if i["vm"] == vm and i["if"] == ifn), None)


# ----------------------------------------------------------------------------
# 2. usuarios.csv
# ----------------------------------------------------------------------------
print("2. Registro de equipos (usuarios.csv)")
csv = [l.split(",") for l in lineas(R1 / "etc/xelaju/usuarios.csv")]
comprobar(csv[0] == ["Equipo", "Direccion_MAC", "IP_reservada"], "cabecera Equipo,Direccion_MAC,IP_reservada")
registro = {f[1].lower(): f[2] for f in csv[1:]}
comprobar(len(registro) == len(csv) - 1 and len(set(registro.values())) == len(registro), "sin MAC ni IP repetidas")
for i in ips:
    mac = nic_de(i["vm"], i["if"])["mac"] if i["if"] == "lan0" else None
    if i["metodo"] == "dhcp":
        comprobar(registro.get(mac) == i["dir"].split("/")[0],
                  f"{i['vm']}: {mac} registrada con {i['dir'].split('/')[0]}", f"CSV dice {registro.get(mac)}")
    elif i["metodo"] == "ninguna":
        comprobar(mac not in registro, f"{i['vm']}: {mac} NO esta registrada (es el equipo intruso)")
red20 = ipaddress.ip_network("192.168.20.0/24")
comprobar(all(ipaddress.ip_address(d) in red20 and 10 <= int(d.split(".")[3]) <= 250 for d in registro.values()),
          "todas las reservas estan en 192.168.20.10-250")

# ----------------------------------------------------------------------------
# 3. Archivos interfaces de cada nodo
# ----------------------------------------------------------------------------
print("3. Direcciones configuradas en cada nodo")


def stanzas(*rutas):
    """{interfaz: {'metodo':..., 'address':..., 'gateway':...}} de archivos de ifupdown."""
    resultado, actual = {}, None
    for ruta in rutas:
        for l in lineas(ruta):
            c = l.split()
            if c[0] == "iface":
                actual = resultado.setdefault(c[1], {"metodo": c[3]})
            elif c[0] in ("address", "gateway") and actual is not None:
                actual[c[0]] = c[1]
    return resultado


def conf_shell(ruta):
    """Variables NOMBRE="valor" de un archivo de shell sencillo."""
    return dict(re.findall(r'^(\w+)="?([^"\n]*)"?$', texto(ruta), re.M))


for vm in vms:
    esperadas = [i for i in ips if i["vm"] == vm]
    if vm.startswith("sw-"):
        conf = conf_shell(REPO / f"nodos/{vm}/switch.conf")
        i = esperadas[0]
        comprobar(conf.get("IP_GESTION") == i["dir"] and conf.get("GW_GESTION") == i["gw"]
                  and i["if"] == f"br0.{conf.get('VLAN_GESTION')}",
                  f"{vm}: gestion {i['dir']} via {i['gw']} en {i['if']}", str(conf))
        continue
    if vm == "r1-lan":
        archivos = {"siempre": [R1 / "etc/network/interfaces"],
                    "individual": [R1 / "etc/network/modos/individual"],
                    "grupal": [R1 / "etc/network/modos/grupal"]}
    else:
        unico = REPO / f"nodos/{vm}/interfaces"
        if not unico.exists():
            unico = REPO / f"nodos/{vm}/rootfs/etc/network/interfaces"
        archivos = {"siempre": [unico]}
    for i in esperadas:
        st = stanzas(*archivos[i["modo"]]).get(i["if"], {})
        if i["metodo"] == "estatica":
            bien = st.get("metodo") == "static" and st.get("address") == i["dir"] and st.get("gateway", "-") == i["gw"]
            comprobar(bien, f"{vm} {i['if']}: {i['dir']} gw {i['gw']} ({i['modo']})", str(st))
        elif i["metodo"] == "dhcp":
            comprobar(st.get("metodo") == "dhcp", f"{vm} {i['if']}: pide su direccion por DHCP", str(st))
        else:
            comprobar(st.get("metodo") == "manual", f"{vm} {i['if']}: sin direccion (manual)", str(st))

# ----------------------------------------------------------------------------
# 4. Tablas de puertos de los switches
# ----------------------------------------------------------------------------
print("4. Puertos de los switches frente a los cables")
vlans_r1 = sorted(int(i["if"].split(".")[1]) for i in ips if i["vm"] == "r1-lan" and "." in i["if"])
tablas = {}
for sw in (v for v in vms if v.startswith("sw-")):
    tablas[sw] = {c[0]: (c[1], c[2]) for c in (l.split() for l in lineas(REPO / f"nodos/{sw}/puertos.conf"))}
for sw, tabla in tablas.items():
    conf = conf_shell(REPO / f"nodos/{sw}/switch.conf")
    declaradas = {int(v.split(":")[0]) for v in conf["VLANS"].split()}
    de_topologia = {n["if"] for n in nics if n["vm"] == sw}
    comprobar(set(tabla) == de_topologia, f"{sw}: puertos.conf lista los mismos puertos que topologia.conf",
              f"{sorted(tabla)} vs {sorted(de_topologia)}")
    for puerto, (modo, valor) in sorted(tabla.items()):
        vecino = otro_extremo(nic_de(sw, puerto))
        if modo == "trunk":
            lista = [int(v) for v in valor.split(",")]
            comprobar(set(lista) <= declaradas, f"{sw} {puerto}: VLAN {valor} declaradas en switch.conf")
            if vecino and vecino["vm"] == "r1-lan":
                comprobar(lista == vlans_r1, f"{sw} {puerto}: troncal a R1 con las VLAN {vlans_r1}", valor)
            elif vecino and vecino["vm"] in tablas:
                m2, v2 = tablas[vecino["vm"]][vecino["if"]]
                comprobar(m2 == "trunk" and v2 == valor,
                          f"{sw} {puerto}: troncal a {vecino['vm']} {vecino['if']} con la misma lista ({valor})", f"{m2} {v2}")
            else:
                fallo(f"{sw} {puerto}: troncal hacia algo que no es R1 ni un switch")
        elif modo == "access":
            comprobar(int(valor) in declaradas, f"{sw} {puerto}: VLAN {valor} declarada en switch.conf")
            dato = ip_de(vecino["vm"]) if vecino else None
            if dato and dato["dir"] != "-":
                tercer = int(dato["dir"].split(".")[2])
                comprobar(int(valor) == tercer, f"{sw} {puerto}: acceso VLAN {valor} = red de {vecino['vm']} ({dato['dir']})")
            elif vecino:
                ok(f"{sw} {puerto}: acceso VLAN {valor} para {vecino['vm']} (sin direccion propia)")
        elif modo == "span":
            comprobar(valor in tabla and nic_de(sw, puerto)["con"] == "aislado",
                      f"{sw} {puerto}: espejo de {valor}, sin cable a otro equipo")
        else:
            comprobar(modo == "apagado", f"{sw} {puerto}: modo conocido", modo)

# ----------------------------------------------------------------------------
# 5. nftables
# ----------------------------------------------------------------------------
print("5. Definiciones de las ACL (nftables)")
defs = dict(re.findall(r"^define\s+(\w+)\s*=\s*(.+?)\s*(?:#.*)?$", texto(R1 / "etc/nftables.d/00-definiciones.nft"), re.M))


def redes(nombre, tabla=None):
    """Conjunto de redes de un 'define': resuelve las referencias $OTRO y las llaves { a, b }."""
    tabla = defs if tabla is None else tabla
    resultado = set()
    for parte in tabla[nombre].strip("{} ").split(","):
        parte = parte.strip()
        if parte.startswith("$"):
            resultado |= redes(parte[1:], tabla)
        else:
            resultado.add(str(ipaddress.ip_network(parte)))
    return resultado


def red_de(vm, ifn):
    return str(ipaddress.ip_interface(ip_de(vm, ifn)["dir"]).network)


def dir_de(vm, ifn="lan0"):
    return ip_de(vm, ifn)["dir"].split("/")[0]


for nombre, ifn in (("RED_ADMIN", "trunk0.10"), ("RED_USERS", "trunk0.20"), ("RED_SERVERS", "trunk0.30"), ("RED_MGMT", "trunk0.40")):
    comprobar(defs.get(nombre) == red_de("r1-lan", ifn), f"{nombre} = {red_de('r1-lan', ifn)}", str(defs.get(nombre)))
for nombre, ifn in (("GW_USERS", "trunk0.20"), ("GW_SERVERS", "trunk0.30"), ("GW_MGMT", "trunk0.40")):
    comprobar(defs.get(nombre) == dir_de("r1-lan", ifn), f"{nombre} = {dir_de('r1-lan', ifn)}", str(defs.get(nombre)))
comprobar(defs.get("ZBX") == dir_de("zbx-srv01"), f"ZBX = {dir_de('zbx-srv01')}")
comprobar(defs.get("INTRANET") == dir_de("srv-intra01"), f"INTRANET = {dir_de('srv-intra01')}")
vlans_topo = {red_de("r1-lan", i["if"]) for i in ips if i["vm"] == "r1-lan" and i["if"].startswith("trunk0.")}
comprobar(redes("REDES_LAN") == vlans_topo, f"REDES_LAN = las {len(vlans_topo)} VLAN de la topologia, una por una (sin resumen)",
          str(sorted(redes("REDES_LAN"))))
comprobar(defs.get("RED_ENLACE_SQUID") == red_de("r1-lan", "up-squid"),
          f"RED_ENLACE_SQUID = red de up-squid ({red_de('r1-lan', 'up-squid')})")
comprobar(defs.get("RED_ENLACE_SQUID") in redes("REDES_TRANSITO"), "REDES_TRANSITO incluye el enlace con Squid")
comprobar(not any(ipaddress.ip_network(t).overlaps(ipaddress.ip_network(v)) for t in redes("REDES_TRANSITO") for v in vlans_topo),
          "las redes de transito no se traslapan con las VLAN")
reglas_r1 = "".join(texto(f) for f in sorted((R1 / "etc/nftables.d").rglob("*.nft")))
ifs_acl = set(re.findall(r'"(trunk0\.\d+|tmp-nat|up-[a-z0-9]+)"', reglas_r1))
ifs_topo = {i["if"] for i in ips if i["vm"] == "r1-lan"}
comprobar(ifs_acl == ifs_topo, "las ACL nombran exactamente las interfaces de R1", f"{sorted(ifs_acl)} vs {sorted(ifs_topo)}")
usadas = set(re.findall(r"\$(\w+)", reglas_r1))
comprobar(usadas <= set(defs), "toda variable usada en las reglas esta definida", ", ".join(sorted(usadas - set(defs))))
defs_zbx = dict(re.findall(r"^define\s+(\w+)\s*=\s*(.+?)\s*(?:#.*)?$", texto(REPO / "nodos/zbx-srv01/rootfs/etc/nftables.conf"), re.M))
comprobar(all(defs_zbx[k] == defs[k] for k in defs_zbx if k in defs), "el cortafuegos de ZBX usa las mismas redes que R1",
          str({k: (defs_zbx[k], defs.get(k)) for k in defs_zbx if defs_zbx[k] != defs.get(k)}))
generado = texto(R1 / "etc/nftables.d/10-registrados.nft")
pares = set(re.findall(r"((?:[0-9a-f]{2}:){5}[0-9a-f]{2}) \. ([0-9.]+)", generado))
comprobar(pares == set(registro.items()), "10-registrados.nft contiene exactamente los pares MAC.IP del CSV")

# ----------------------------------------------------------------------------
# 6. DHCP
# ----------------------------------------------------------------------------
print("6. DHCP restringido")
dhcpd = "\n".join(lineas(R1 / "etc/dhcp/dhcpd.conf"))
gw20 = ipaddress.ip_interface(ip_de("r1-lan", "trunk0.20")["dir"])
comprobar(f"subnet {gw20.network.network_address} netmask {gw20.netmask}" in dhcpd, f"subnet {gw20.network} declarada")
comprobar(f"option routers {gw20.ip};" in dhcpd, f"puerta de enlace entregada = {gw20.ip}")
comprobar(f"option broadcast-address {gw20.network.broadcast_address};" in dhcpd, "direccion de difusion correcta")
comprobar("range" not in dhcpd, "sin 'range': no hay direcciones dinamicas")
comprobar("boot-unknown-clients false;" in dhcpd and "authoritative;" in dhcpd, "authoritative y boot-unknown-clients false")
comprobar('INTERFACESv4="trunk0.20"' in texto(R1 / "etc/default/isc-dhcp-server"), "dhcpd escucha solo en trunk0.20")
reservas = texto(R1 / "etc/dhcp/reservas-vlan20.conf")
pares_res = set(re.findall(r"hardware ethernet ([0-9a-f:]+);\s+fixed-address ([0-9.]+);", reservas))
comprobar(pares_res == set(registro.items()), "reservas-vlan20.conf contiene exactamente las reservas del CSV")

# ----------------------------------------------------------------------------
# 7. Varios
# ----------------------------------------------------------------------------
print("7. /etc/hosts, matriz de pruebas, URL de Zabbix y documentacion")
hosts = {}
for l in lineas(REPO / "nodos/_comun/hosts.xelaju"):
    c = l.split()
    for nombre in c[1:]:
        hosts[nombre] = c[0]
malos = [f"{i['vm']}={hosts.get(i['vm'])}" for i in ips
         if i["dir"] != "-" and i["vm"] != "r1-lan" and hosts.get(i["vm"]) != i["dir"].split("/")[0]]
comprobar(not malos, "hosts.xelaju coincide con las direcciones de la topologia", ", ".join(malos))

for matriz in ("pruebas/matriz.conf", "grupal/matriz-grupal.conf"):
    perfiles, casos = {}, []
    for l in lineas(REPO / matriz):
        if l.startswith("perfil "):
            perfiles[l.split()[1]] = l.split()[2]
        elif "|" in l:
            casos.append([c.strip() for c in l.split("|")])
    comprobar(all(len(c) == 7 for c in casos), f"{matriz}: {len(casos)} casos con 7 campos")
    comprobar(all(c[1] in perfiles for c in casos), f"{matriz}: todos los casos usan un perfil declarado")
    comprobar(len({c[0] for c in casos}) == len(casos), f"{matriz}: identificadores de caso unicos")
    if matriz == "pruebas/matriz.conf":
        comprobar(all(v in vms for v in perfiles.values()), f"{matriz}: los perfiles se ejecutan en VMs existentes")
        malos = [c[0] for c in casos if c[2] == "ip" and ip_de(perfiles[c[1]])["dir"].split("/")[0] != c[5]]
        comprobar(not malos, f"{matriz}: las direcciones esperadas (tipo ip) son las de la topologia", ", ".join(malos))

patron = r'https://repo\.zabbix\.com/[^"\s]+\.deb'
urls = {re.search(patron, texto(REPO / f)).group(0) for f in ("lab/base/post-base.sh", "nodos/_comun/comun.sh")}
comprobar(len(urls) == 1, "misma URL del repositorio de Zabbix en post-base.sh y comun.sh", str(urls))

diseno = REPO / "docs/01-diseno-red.md"
if diseno.exists():
    doc = texto(diseno)
    faltan = sorted({i["dir"].split("/")[0] for i in ips if i["dir"] != "-" and i["dir"].split("/")[0] not in doc}
                    | {n["mac"] for n in nics if n["mac"] not in doc})
    comprobar(not faltan, "docs/01-diseno-red.md nombra todas las direcciones IP y MAC de la topologia", ", ".join(faltan))
else:
    print("  [ -- ] docs/01-diseno-red.md todavia no existe")

equipos = texto(REPO / "grupal/EQUIPOS-LAN.md")
faltan = sorted({i["dir"].split("/")[0] for i in ips if i["dir"] != "-" and i["dir"].split("/")[0] not in equipos}
                | {l.split(",")[n] for l in lineas(R1 / "etc/xelaju/usuarios.csv")[1:] for n in (1, 2)
                   if l.split(",")[n] not in equipos})
comprobar(not faltan, "grupal/EQUIPOS-LAN.md nombra todas las direcciones IP de la topologia y las reservas DHCP", ", ".join(faltan))

# ----------------------------------------------------------------------------
# 8. core/ADDRESSING.yaml (fuente de verdad del grupo)
# ----------------------------------------------------------------------------
# Este componente vive en nodes/E1-lan/ del repositorio de coordinacion; los
# datos compartidos estan dos carpetas mas arriba, en core/. Aqui no se decide
# ningun valor: solo se comprueba que E1 usa los mismos. Si core/ cambia, este
# bloque falla y dice que hay que actualizar en E1.
print("8. Datos compartidos del grupo (core/ADDRESSING.yaml)")
CORE = REPO.parent.parent / "core/ADDRESSING.yaml"
if not CORE.exists():
    print("  [ -- ] no se encuentra core/ADDRESSING.yaml (el componente se copio fuera del repositorio del grupo): se omite")
else:
    # Se quitan los comentarios para que un '#' no confunda a las expresiones
    yaml = "\n".join(l.split(" #", 1)[0].rstrip() for l in texto(CORE).splitlines() if not l.lstrip().startswith("#"))

    def uno(patron, que):
        """Primer grupo de la primera coincidencia, o None (y un fallo) si el dato no esta."""
        m = re.search(patron, yaml, re.S)
        if not m:
            fallo(f"core/: no se encontro {que}")
            return None
        return m.group(1)

    # VLAN: identificador, red y puerta de enlace
    vlans_core = {int(v): (red, gw) for v, red, gw in
                  re.findall(r'vlan_id:\s*(\d+)\s*\n\s*subnet:\s*"([^"]+)"\s*\n\s*gateway:\s*"([^"]+)"', yaml)}
    vlans_e1 = {int(i["if"].split(".")[1]): (red_de("r1-lan", i["if"]), dir_de("r1-lan", i["if"]))
                for i in ips if i["vm"] == "r1-lan" and i["if"].startswith("trunk0.")}
    comprobar(vlans_core == vlans_e1, f"VLAN {sorted(vlans_e1)}: mismas redes y puertas de enlace que core/",
              f"core={vlans_core} E1={vlans_e1}")

    # Enlace E1-E2 y ruta por defecto de E1
    enlace = uno(r'id:\s*"link_e1_e2".*?subnet:\s*"([^"]+)"', "link_e1_e2")
    e2_ip = uno(r'id:\s*"link_e1_e2".*?e2_ip:\s*"([^"]+)"', "link_e1_e2.e2_ip")
    e1_ip = uno(r'id:\s*"link_e1_e2".*?e1_ip:\s*"([^"]+)"', "link_e1_e2.e1_ip")
    salto = uno(r'routing_plan:.*?E1_lan:\s*\n\s*-\s*\{\s*destination:\s*"0\.0\.0\.0/0",\s*next_hop:\s*"([^"]+)"', "la ruta por defecto de E1")
    up = ip_de("r1-lan", "up-squid")
    comprobar(red_de("r1-lan", "up-squid") == enlace and dir_de("r1-lan", "up-squid") == e1_ip,
              f"up-squid = {e1_ip} en {enlace} (link_e1_e2)", up["dir"])
    comprobar(up["gw"] == e2_ip == salto, f"ruta por defecto de R1 via {salto} (E2)", f"gw={up['gw']} e2_ip={e2_ip}")

    # Todos los enlaces /30 del grupo: son los origenes que R1 y ZBX aceptan para el monitoreo
    enlaces_core = set(re.findall(r'id:\s*"link_\w+"\s*\n\s*description:[^\n]*\n\s*subnet:\s*"([^"]+)"', yaml))
    comprobar(redes("REDES_TRANSITO") == enlaces_core and len(enlaces_core) == 4,
              "REDES_TRANSITO = los 4 enlaces de inter_node_links", f"core={sorted(enlaces_core)}")

    # Zabbix
    zbx_core = uno(r'zabbix:\s*\n\s*server_ip:\s*"([^"]+)"', "zabbix.server_ip")
    comprobar(zbx_core == dir_de("zbx-srv01"), f"servidor Zabbix en {zbx_core}", dir_de("zbx-srv01"))

    # Redes VPN
    vpn_admin = uno(r'name:\s*"vpn_admin".*?subnet:\s*"([^"]+)"', "vpn_admin")
    vpn_users = uno(r'name:\s*"vpn_users".*?subnet:\s*"([^"]+)"', "vpn_users")
    comprobar(defs.get("RED_VPN_ADMIN") == vpn_admin and defs.get("RED_VPN_USERS") == vpn_users
              and redes("REDES_VPN") == {vpn_admin, vpn_users},
              f"redes VPN = {vpn_admin} y {vpn_users}", f"{defs.get('RED_VPN_ADMIN')} {defs.get('RED_VPN_USERS')}")
    comprobar(defs_zbx.get("RED_VPN_ADMIN") == vpn_admin, "el cortafuegos de ZBX usa la misma red VPN-ADMIN")

    # DMZ: E1 no la nombra en sus reglas; solo la usan las pruebas grupales
    dmz = uno(r'dmz_segment:.*?subnet:\s*"([^"]+)"', "dmz_segment.subnet")
    web01 = uno(r'name:\s*"WEB01"\s*\n\s*ip_address:\s*"([^"]+)"', "la IP de WEB01")
    matriz_g = texto(REPO / "grupal/matriz-grupal.conf")
    ensayo = texto(REPO / "pruebas/simular-lan.sh")
    comprobar(dmz is not None and web01 is not None and f"{web01}:" in matriz_g and f'DMZ="{dmz}"' in ensayo
              and f"{web01}/" in ensayo,
              f"las pruebas grupales usan la DMZ {dmz} y WEB01 {web01} de core/")
    for nombre, ip_core in (("E3 hacia E5", uno(r'id:\s*"link_e3_e5".*?e3_ip:\s*"([^"]+)"', "link_e3_e5.e3_ip")),
                            ("E4 hacia E5", uno(r'id:\s*"link_e4_e5".*?e4_ip:\s*"([^"]+)"', "link_e4_e5.e4_ip"))):
        comprobar(ip_core is not None and f"{ip_core}/30" in ensayo, f"el ensayo grupal usa {ip_core} para {nombre}")

    # isp-activo.sh: sondea el salto siguiente a E3 con origen en cada puerta de enlace de R1
    monitor = texto(REPO / "grupal/isp-activo.sh")
    e3_ip = uno(r'id:\s*"link_e3_e5".*?e3_ip:\s*"([^"]+)"', "link_e3_e5.e3_ip")
    comprobar(e3_ip is not None and f'IP_E3="{e3_ip}"' in monitor, f"isp-activo.sh busca a E3 en {e3_ip}")
    origenes = set(re.findall(r'^\s+"\w+\s+([\d.]+)\s+(?:tcp|udp)\s+\d+"', monitor, re.M))
    comprobar(origenes == {gw for _, gw in vlans_e1.values()},
              "isp-activo.sh sondea desde las puertas de enlace de las VLAN", str(sorted(origenes)))

    # Sus dos clases de referencia dependen de las politicas publicadas por E3
    politicas = REPO.parent / "E3-multiwan/config/policies.txt"
    if not politicas.exists():
        print("  [ -- ] no se encuentra policies.txt de E3: no se comprueban las referencias de isp-activo.sh")
    else:
        reglas = [re.match(r'([\d./]+),\s*\[([\d,\s]*)\],\s*(\w+),\s*(ISP\d)', l) for l in lineas(politicas)]
        for isp in ("ISP1", "ISP2"):
            origen, proto, puerto = re.search(rf'^REF_{isp}="([\d.]+) (\w+) (\d+)"', monitor, re.M).groups()
            salidas = {m.group(4) for m in reglas
                       if m and ipaddress.ip_address(origen) in ipaddress.ip_network(m.group(1), strict=False)
                       and m.group(3).upper() in (proto.upper(), "ANY")
                       and puerto in m.group(2).replace(" ", "").split(",")}
            comprobar(salidas == {isp}, f"isp-activo.sh: E3 saca {origen} {proto}/{puerto} siempre por {isp} (referencia)",
                      f"policies.txt de E3 dice {sorted(salidas) or 'que no hay politica: sale balanceado'}")

print()
if fallos:
    print(f"RESULTADO: {fallos} incoherencia(s)")
    sys.exit(1)
print("RESULTADO: todo coincide")
