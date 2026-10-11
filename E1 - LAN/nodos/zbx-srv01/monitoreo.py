#!/usr/bin/env python3
"""monitoreo.py - configura el monitoreo de XelajuNetwork por la API de Zabbix.

Hace por consola lo mismo que docs/03-zabbix.md describe para la interfaz web:

  1. Grupos de equipos:  XelajuNetwork/LAN  y  XelajuNetwork/Multi-WAN
  2. Autorregistro:      los agentes de la LAN, que se anuncian con HostMetadata
                         'xelaju-lan', se dan de alta solos con la plantilla
                         "Linux by Zabbix agent active"
  3. Equipos por ping:   los PC (sin agente) con la plantilla "ICMP Ping"
  4. Items de R1-LAN:    equipos registrados, concesiones y rechazos DHCP, bloqueos ACL
  5. Multi-WAN (Est. 3): el equipo "Router-MultiWAN-E3" con el trafico de entrada
                         y de salida de ISP1 e ISP2 (los contadores que publica
                         su agente, convertidos a bits y paquetes por segundo)
  6. Dashboards:         "LAN - Estudiante 1"  y  "Multi-WAN - Estudiante 3"

Se ejecuta en ZBX-SRV01 como root (la API solo se atiende desde 127.0.0.1 y
desde la VLAN ADMIN):

    /mnt/proyecto/nodos/zbx-srv01/monitoreo.py [--clave CLAVE] [--esperar SEG]

Es idempotente: lo que ya existe no se vuelve a crear (los dashboards se
reescriben para que queden como dice este archivo). Los items de R1-LAN y el
dashboard de la LAN necesitan que R1-LAN ya se haya registrado; si todavia no
aparece, el guion lo dice y basta con repetirlo mas tarde.

La API de Zabbix es JSON-RPC sobre HTTP: se envia {"method": ..., "params": ...}
y se recibe {"result": ...} o {"error": ...}. Solo biblioteca estandar.
"""

import argparse
import json
import sys
import time
import urllib.request
from pathlib import Path

URL = "http://127.0.0.1/zabbix/api_jsonrpc.php"
TOPOLOGIA = Path(__file__).resolve().parents[2] / "lab" / "topologia.conf"

GRUPO_LAN = "XelajuNetwork/LAN"
GRUPO_WAN = "XelajuNetwork/Multi-WAN"
PLANTILLA_AGENTE = "Linux by Zabbix agent active"
PLANTILLA_PING = "ICMP Ping"

# Items propios de R1-LAN (UserParameter de /etc/zabbix/zabbix_agent2.d/xelaju-r1.conf)
ITEMS_R1 = [
    ("Equipos registrados (DHCP)", "xelaju.dhcp.registrados"),
    ("DHCP: concesiones (DHCPACK)", "xelaju.dhcp.ack"),
    ("DHCP: rechazos a no registrados", "xelaju.dhcp.rechazos"),
    ("ACL: paquetes bloqueados", "xelaju.acl.bloqueos"),
]

# Multi-WAN del Estudiante 3. Nombre del equipo y claves son los que YA publica
# su agente (nodes/E3-multiwan/scripts/zabbix_agent_multiwan.sh): no se inventan
# aqui. La IP es la de E3 en el enlace E3-E5 de core/ADDRESSING.yaml.
EQUIPO_WAN = "Router-MultiWAN-E3"
# Nombre visible del equipo en la web. Los widgets de grafica eligen el equipo por
# este nombre, no por el del agente: con el otro, las graficas salian vacias.
NOMBRE_WAN = "Multi-WAN (Estudiante 3)"
IP_WAN = "192.168.81.1"
# (nombre del item, clave, unidad). Las claves entregan CONTADORES que solo
# crecen (bytes o paquetes desde que arranco la interfaz); el item los
# convierte en velocidad con dos pasos de preprocesado.
ITEMS_WAN = [
    ("ISP1 entrada", "multiwan.isp1.rx_bytes", "bps"),
    ("ISP1 salida", "multiwan.isp1.tx_bytes", "bps"),
    ("ISP1 paquetes de entrada", "multiwan.isp1.rx_packets", "pps"),
    ("ISP1 paquetes de salida", "multiwan.isp1.tx_packets", "pps"),
    ("ISP2 entrada", "multiwan.isp2.rx_bytes", "bps"),
    ("ISP2 salida", "multiwan.isp2.tx_bytes", "bps"),
    ("ISP2 paquetes de entrada", "multiwan.isp2.rx_packets", "pps"),
    ("ISP2 paquetes de salida", "multiwan.isp2.tx_packets", "pps"),
]


def bien(texto):
    print(f"    [ OK ] {texto}")


def aviso(texto):
    print(f"    [AVISO] {texto}")


class Zabbix:
    """Cliente minimo de la API de Zabbix."""

    def __init__(self, url):
        self.url = url
        self.token = None
        self.n = 0

    def llamar(self, metodo, **parametros):
        self.n += 1
        cuerpo = json.dumps({"jsonrpc": "2.0", "method": metodo, "params": parametros, "id": self.n}).encode()
        cabeceras = {"Content-Type": "application/json-rpc"}
        if self.token:                       # desde 6.4 la sesion viaja en esta cabecera
            cabeceras["Authorization"] = "Bearer " + self.token
        peticion = urllib.request.Request(self.url, cuerpo, cabeceras)
        with urllib.request.urlopen(peticion, timeout=60) as respuesta:
            datos = json.load(respuesta)
        if "error" in datos:
            e = datos["error"]
            raise RuntimeError(f"{metodo}: {e.get('data') or e.get('message')}")
        return datos["result"]

    def entrar(self, usuario, clave):
        self.token = self.llamar("user.login", username=usuario, password=clave)

    def salir(self):
        try:
            self.llamar("user.logout")
        except (RuntimeError, OSError):
            pass


# ---------------------------------------------------------------------------
# 1. Grupos y plantillas
# ---------------------------------------------------------------------------
def grupo(z, nombre):
    """Devuelve el id del grupo de equipos; lo crea si no existe."""
    hay = z.llamar("hostgroup.get", filter={"name": [nombre]}, output=["groupid"])
    if hay:
        return hay[0]["groupid"]
    creado = z.llamar("hostgroup.create", name=nombre)["groupids"][0]
    bien(f"grupo creado: {nombre}")
    return creado


def plantilla(z, nombre):
    hay = z.llamar("template.get", filter={"host": [nombre]}, output=["templateid"])
    if not hay:
        raise RuntimeError(f"no existe la plantilla '{nombre}' en este Zabbix")
    return hay[0]["templateid"]


def descubrimiento_de_interfaces(z, id_plantilla, intervalo="5m"):
    """Hace que la plantilla busque las interfaces de red cada 5 minutos.

    Los items "Interface trunk0.10: Bits received", etc. no existen hasta que
    la regla de descubrimiento "net.if.discovery" se ejecuta, y de fabrica lo
    hace una vez por hora: el dashboard de la LAN estaria vacio todo ese
    tiempo. Con 5 minutos aparecen pronto; el costo en un laboratorio es nulo.
    """
    regla = z.llamar("discoveryrule.get", templateids=id_plantilla, filter={"key_": "net.if.discovery"},
                     output=["itemid", "delay"])
    if not regla:
        aviso("la plantilla no tiene la regla net.if.discovery: las interfaces no se descubriran")
        return
    if regla[0]["delay"] != intervalo:
        z.llamar("discoveryrule.update", itemid=regla[0]["itemid"], delay=intervalo)
        bien(f"descubrimiento de interfaces de red: cada {intervalo} (antes, {regla[0]['delay']})")


# ---------------------------------------------------------------------------
# 2. Autorregistro
# ---------------------------------------------------------------------------
def accion_autorregistro(z, nombre, metadato, id_grupo, id_plantilla):
    if z.llamar("action.get", filter={"name": [nombre], "eventsource": 2}, output=["actionid"]):
        return
    z.llamar(
        "action.create",
        name=nombre,
        eventsource=2,                      # 2 = eventos de autorregistro
        status=0,                           # 0 = habilitada
        filter={
            "evaltype": 0,
            # tipo 24 = metadato del equipo; operador 2 = "contiene"
            "conditions": [{"conditiontype": 24, "operator": 2, "value": metadato}],
        },
        operations=[
            {"operationtype": 2},                                            # agregar el equipo
            {"operationtype": 4, "opgroup": [{"groupid": id_grupo}]},        # meterlo en el grupo
            {"operationtype": 6, "optemplate": [{"templateid": id_plantilla}]},   # enlazar la plantilla
        ],
    )
    bien(f"accion de autorregistro creada: {nombre} (metadato '{metadato}')")


# ---------------------------------------------------------------------------
# 3. Equipos vigilados solo por ping
# ---------------------------------------------------------------------------
def equipos_ping():
    """(NOMBRE, ip) de los PC de lab/topologia.conf que tienen direccion."""
    lista = []
    for linea in TOPOLOGIA.read_text().splitlines():
        c = linea.split("#", 1)[0].split()
        if len(c) >= 4 and c[0] == "ip" and c[1].startswith("pc-") and c[3] != "-":
            lista.append((c[1].upper(), c[3].split("/")[0]))
    return lista


def equipo_ping(z, nombre, ip, id_grupo, id_plantilla):
    if z.llamar("host.get", filter={"host": [nombre]}, output=["hostid"]):
        return
    z.llamar(
        "host.create",
        host=nombre,
        groups=[{"groupid": id_grupo}],
        templates=[{"templateid": id_plantilla}],
        # La interfaz solo indica a que IP hacer ping (lo hace el servidor)
        interfaces=[{"type": 1, "main": 1, "useip": 1, "ip": ip, "dns": "", "port": "10050"}],
    )
    bien(f"equipo por ping creado: {nombre} ({ip})")


# ---------------------------------------------------------------------------
# 4. Items propios de R1-LAN
# ---------------------------------------------------------------------------
def id_equipo(z, nombre):
    hay = z.llamar("host.get", filter={"host": [nombre]}, output=["hostid"])
    return hay[0]["hostid"] if hay else None


def items_r1(z, id_r1):
    """Crea los items que falten y devuelve {clave: itemid}."""
    ids = {}
    for nombre, clave in ITEMS_R1:
        hay = z.llamar("item.get", hostids=id_r1, filter={"key_": clave}, output=["itemid"])
        if hay:
            ids[clave] = hay[0]["itemid"]
            continue
        ids[clave] = z.llamar(
            "item.create",
            name=nombre,
            key_=clave,
            hostid=id_r1,
            type=7,                         # 7 = agente Zabbix (activo)
            value_type=3,                   # 3 = numero entero sin signo
            delay="1m",
        )["itemids"][0]
        bien(f"item creado en R1-LAN: {clave}")
    return ids


# ---------------------------------------------------------------------------
# 5. Multi-WAN del Estudiante 3
# ---------------------------------------------------------------------------
def equipo_multiwan(z, id_grupo):
    """Crea el equipo del Multi-WAN si no existe y devuelve su id.

    No se usa autorregistro: el agente de E3 no envia HostMetadata, asi que el
    equipo se da de alta aqui con el mismo nombre que el agente usa en su
    parametro Hostname. Cuando el agente pregunte "que debo medir", el servidor
    le contestara con los items de abajo.
    """
    hay = id_equipo(z, EQUIPO_WAN)
    if hay:
        return hay
    creado = z.llamar(
        "host.create",
        host=EQUIPO_WAN,
        name=NOMBRE_WAN,
        groups=[{"groupid": id_grupo}],
        # Los items son activos (el agente abre la conexion); la interfaz solo
        # deja anotada la direccion del equipo
        interfaces=[{"type": 1, "main": 1, "useip": 1, "ip": IP_WAN, "dns": "", "port": "10050"}],
    )["hostids"][0]
    bien(f"equipo creado: {EQUIPO_WAN} ({IP_WAN})")
    return creado


def items_multiwan(z, id_wan):
    """Crea los items que falten y devuelve {clave: itemid}."""
    ids = {}
    for nombre, clave, unidad in ITEMS_WAN:
        hay = z.llamar("item.get", hostids=id_wan, filter={"key_": clave}, output=["itemid"])
        if hay:
            ids[clave] = hay[0]["itemid"]
            continue
        # Paso 1 (tipo 10, "cambio por segundo"): (valor - valor anterior) / segundos
        # entre las dos muestras = bytes/s o paquetes/s.
        pasos = [{"type": 10, "params": "", "error_handler": 0, "error_handler_params": ""}]
        if unidad == "bps":
            # Paso 2 (tipo 1, "multiplicador"): bytes/s x 8 = bits/s
            pasos.append({"type": 1, "params": "8", "error_handler": 0, "error_handler_params": ""})
        ids[clave] = z.llamar(
            "item.create",
            name=nombre,
            key_=clave,
            hostid=id_wan,
            type=7,                         # 7 = agente Zabbix (activo)
            value_type=0,                   # 0 = numero decimal
            units=unidad,
            delay="30s",
            preprocessing=pasos,
        )["itemids"][0]
        bien(f"item creado en {EQUIPO_WAN}: {clave} -> {nombre} ({unidad})")
    return ids


# ---------------------------------------------------------------------------
# 6. Dashboards
# ---------------------------------------------------------------------------
# Un dashboard es una rejilla de 72 columnas. Cada widget tiene posicion (x, y),
# tamano y una lista de campos {type, name, value}; type 1 = texto,
# 0 = entero, 2 = grupo de equipos, 4 = item.
def grafica(nombre, ref, x, y, ancho, alto, series):
    """Widget de grafica; series = [(equipo, patron de item, color), ...]."""
    campos = [{"type": 1, "name": "reference", "value": ref}]
    for i, (equipo, patron, color) in enumerate(series):
        campos += [
            {"type": 1, "name": f"ds.{i}.hosts.0", "value": equipo},
            {"type": 1, "name": f"ds.{i}.items.0", "value": patron},
            {"type": 1, "name": f"ds.{i}.color", "value": color},
        ]
    return {"type": "svggraph", "name": nombre, "x": x, "y": y, "width": ancho, "height": alto, "fields": campos}


def valor(nombre, x, y, ancho, alto, id_item):
    return {"type": "item", "name": nombre, "x": x, "y": y, "width": ancho, "height": alto,
            "fields": [{"type": 4, "name": "itemid.0", "value": id_item}]}


def por_grupo(tipo, nombre, x, y, ancho, alto, id_grupo, ref=None):
    campos = [{"type": 2, "name": "groupids.0", "value": id_grupo}]
    if ref:
        campos.append({"type": 1, "name": "reference", "value": ref})
    return {"type": tipo, "name": nombre, "x": x, "y": y, "width": ancho, "height": alto, "fields": campos}


def dashboard(z, nombre, widgets):
    """Crea el dashboard o, si ya existe, lo deja con los widgets de este archivo."""
    hay = z.llamar("dashboard.get", filter={"name": [nombre]}, output=["dashboardid"])
    if hay:
        z.llamar("dashboard.update", dashboardid=hay[0]["dashboardid"], pages=[{"widgets": widgets}])
        return
    z.llamar("dashboard.create", name=nombre, display_period=30, auto_start=1,
             private=0, pages=[{"widgets": widgets}])
    bien(f"dashboard creado: {nombre}")


def dashboard_lan(z, id_grupo, items):
    widgets = [
        grafica("Trafico por VLAN en R1-LAN (bits/s)", "XJLA1", 0, 0, 36, 5, [
            ("R1-LAN", "Interface trunk0.*: Bits received", "1E88E5"),
            ("R1-LAN", "Interface trunk0.*: Bits sent", "E53935"),
        ]),
        grafica("Troncal SW-CORE01 p0 hacia R1 (bits/s)", "XJLA2", 36, 0, 36, 5, [
            ("SW-CORE01", "Interface p0: Bits received", "43A047"),
            ("SW-CORE01", "Interface p0: Bits sent", "FB8C00"),
        ]),
        por_grupo("hostavail", "Disponibilidad de los equipos de la LAN", 0, 5, 24, 3, id_grupo),
        por_grupo("problems", "Problemas activos en la LAN", 24, 5, 48, 6, id_grupo, "XJLA3"),
        valor("Equipos registrados (DHCP)", 0, 8, 12, 3, items["xelaju.dhcp.registrados"]),
        valor("Concesiones DHCP", 12, 8, 12, 3, items["xelaju.dhcp.ack"]),
        valor("Rechazos DHCP", 0, 11, 12, 3, items["xelaju.dhcp.rechazos"]),
        valor("Bloqueos de las ACL", 12, 11, 12, 3, items["xelaju.acl.bloqueos"]),
        grafica("Bloqueos de las ACL y rechazos DHCP", "XJLA4", 24, 11, 48, 5, [
            ("R1-LAN", "ACL: paquetes bloqueados", "D81B60"),
            ("R1-LAN", "DHCP: rechazos a no registrados", "8E24AA"),
        ]),
    ]
    dashboard(z, "LAN - Estudiante 1", widgets)


def dashboard_multiwan(z, id_grupo, items):
    widgets = [
        grafica("ISP1: trafico de entrada y de salida (bits/s)", "XJWA1", 0, 0, 36, 6, [
            (NOMBRE_WAN, "ISP1 entrada", "1E88E5"),
            (NOMBRE_WAN, "ISP1 salida", "E53935"),
        ]),
        grafica("ISP2: trafico de entrada y de salida (bits/s)", "XJWA2", 36, 0, 36, 6, [
            (NOMBRE_WAN, "ISP2 entrada", "43A047"),
            (NOMBRE_WAN, "ISP2 salida", "FB8C00"),
        ]),
        valor("ISP1 entrada", 0, 6, 9, 3, items["multiwan.isp1.rx_bytes"]),
        valor("ISP1 salida", 9, 6, 9, 3, items["multiwan.isp1.tx_bytes"]),
        valor("ISP2 entrada", 18, 6, 9, 3, items["multiwan.isp2.rx_bytes"]),
        valor("ISP2 salida", 27, 6, 9, 3, items["multiwan.isp2.tx_bytes"]),
        grafica("Paquetes por segundo en ISP1 e ISP2", "XJWA3", 36, 6, 36, 6, [
            (NOMBRE_WAN, "ISP1 paquetes de entrada", "1E88E5"),
            (NOMBRE_WAN, "ISP1 paquetes de salida", "E53935"),
            (NOMBRE_WAN, "ISP2 paquetes de entrada", "43A047"),
            (NOMBRE_WAN, "ISP2 paquetes de salida", "FB8C00"),
        ]),
        por_grupo("hostavail", "Disponibilidad del Multi-WAN", 0, 9, 36, 3, id_grupo),
        por_grupo("problems", "Problemas activos en el Multi-WAN", 0, 12, 72, 5, id_grupo, "XJWA4"),
    ]
    dashboard(z, "Multi-WAN - Estudiante 3", widgets)


# ---------------------------------------------------------------------------
def main():
    p = argparse.ArgumentParser(description="Configura el monitoreo de XelajuNetwork por la API de Zabbix.")
    p.add_argument("--usuario", default="Admin")
    p.add_argument("--clave", default="zabbix", help="contrasena del usuario de Zabbix (por omision, la de fabrica)")
    p.add_argument("--esperar", type=int, default=0, help="segundos a esperar a que R1-LAN se registre solo")
    a = p.parse_args()

    z = Zabbix(URL)
    try:
        z.entrar(a.usuario, a.clave)
    except (RuntimeError, OSError) as e:
        print(f"    [ERROR] no se pudo entrar a la API de Zabbix como {a.usuario}: {e}", file=sys.stderr)
        return 1
    pendiente = False
    try:
        g_lan, g_wan = grupo(z, GRUPO_LAN), grupo(z, GRUPO_WAN)
        t_agente, t_ping = plantilla(z, PLANTILLA_AGENTE), plantilla(z, PLANTILLA_PING)
        bien(f"grupos {GRUPO_LAN} y {GRUPO_WAN}; plantillas localizadas")
        descubrimiento_de_interfaces(z, t_agente)

        accion_autorregistro(z, "Autorregistro LAN", "xelaju-lan", g_lan, t_agente)
        bien("accion de autorregistro de la LAN presente")

        for nombre, ip in equipos_ping():
            equipo_ping(z, nombre, ip, g_lan, t_ping)
        bien(f"equipos por ping presentes: {', '.join(n for n, _ in equipos_ping())}")

        limite = time.time() + a.esperar
        id_r1 = id_equipo(z, "R1-LAN")
        while not id_r1 and time.time() < limite:
            time.sleep(5)
            id_r1 = id_equipo(z, "R1-LAN")
        if id_r1:
            items = items_r1(z, id_r1)
            bien("items propios de R1-LAN presentes")
            dashboard_lan(z, g_lan, items)
            bien("dashboard 'LAN - Estudiante 1' presente")
        else:
            pendiente = True
            aviso("R1-LAN todavia no se ha registrado: faltan sus items y el dashboard de la LAN")
            aviso("repita este guion cuando el agente de R1 este en marcha")
        id_wan = equipo_multiwan(z, g_wan)
        items_wan = items_multiwan(z, id_wan)
        bien(f"equipo {EQUIPO_WAN} con sus {len(items_wan)} items (trafico de ISP1 e ISP2)")
        dashboard_multiwan(z, g_wan, items_wan)
        bien("dashboard 'Multi-WAN - Estudiante 3' presente")
    except RuntimeError as e:
        print(f"    [ERROR] {e}", file=sys.stderr)
        return 1
    finally:
        z.salir()
    return 2 if pendiente else 0


if __name__ == "__main__":
    sys.exit(main())
