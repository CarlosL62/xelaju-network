#!/usr/bin/env python3
"""qemuctl.py - control de las VMs del laboratorio XelajuNetwork por sus sockets.

Cada VM que arranca lab.sh expone dos sockets UNIX en lab/run/:

  <vm>.qmp  QMP (QEMU Machine Protocol): habla con el hipervisor.
            Sirve para apagar la VM, consultar su estado y capturar trafico
            en un "cable" con el objeto filter-dump (genera un .pcap).
  <vm>.qga  QGA (QEMU Guest Agent): habla con el servicio qemu-guest-agent
            que corre DENTRO del invitado. Sirve para ejecutar comandos sin
            pasar por la red (guest-exec), que es como lab.sh lanza las pruebas.

Los dos protocolos son JSON, un mensaje por linea. Solo se usa la biblioteca
estandar de Python, para no instalar nada en el host.

Uso:
  qemuctl.py estado   <vm.qmp>
  qemuctl.py apagar   <vm.qmp>                 apagado ordenado (boton de encendido ACPI)
  qemuctl.py salir    <vm.qmp>                 cierra QEMU de inmediato (como desenchufar)
  qemuctl.py hmp      <vm.qmp> <orden...>      orden del monitor "humano", p. ej.: info network
  qemuctl.py capturar <vm.qmp> <netdev> <archivo.pcap> [--segundos N]
  qemuctl.py agente   <vm.qga>                 comprueba que el agente del invitado responde
  qemuctl.py exec     [--limite S] <vm.qga> -- <orden de shell...>
                      (--limite va ANTES del socket: todo lo que sigue al
                       socket se toma como la orden a ejecutar)
"""

import argparse
import base64
import json
import os
import socket
import sys
import time

RUTA_INVITADO = "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"


class ErrorQemu(Exception):
    """Fallo de comunicacion con QEMU o con el agente del invitado."""


class Canal:
    """Socket UNIX con mensajes JSON separados por salto de linea."""

    def __init__(self, ruta, espera=5.0):
        self.ruta = ruta
        self.buf = b""
        self.s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.s.settimeout(espera)
        try:
            self.s.connect(ruta)
        except OSError as e:
            raise ErrorQemu(f"no se pudo conectar a {ruta}: {e.strerror or e}")

    def enviar(self, objeto):
        self.s.sendall(json.dumps(objeto).encode() + b"\n")

    def recibir_linea(self):
        while b"\n" not in self.buf:
            try:
                dato = self.s.recv(65536)
            except socket.timeout:
                raise ErrorQemu("sin respuesta (tiempo agotado)")
            if not dato:
                raise ErrorQemu("el otro extremo cerro la conexion")
            self.buf += dato
        linea, self.buf = self.buf.split(b"\n", 1)
        return linea

    def cerrar(self):
        try:
            self.s.close()
        except OSError:
            pass


class Qmp(Canal):
    """Cliente QMP: saludo, negociacion de capacidades y ordenes."""

    def __init__(self, ruta, espera=5.0):
        super().__init__(ruta, espera)
        saludo = json.loads(self.recibir_linea())
        if "QMP" not in saludo:
            raise ErrorQemu("el socket no respondio con el saludo QMP")
        self.version = saludo["QMP"]["version"]["qemu"]
        self.orden("qmp_capabilities")

    def orden(self, nombre, **argumentos):
        mensaje = {"execute": nombre}
        if argumentos:
            mensaje["arguments"] = argumentos
        self.enviar(mensaje)
        while True:
            respuesta = json.loads(self.recibir_linea())
            if "event" in respuesta:        # avisos asincronos (SHUTDOWN, RESUME...): se ignoran
                continue
            if "error" in respuesta:
                raise ErrorQemu(f"{nombre}: {respuesta['error'].get('desc', respuesta['error'])}")
            return respuesta.get("return")


class Qga(Canal):
    """Cliente del agente del invitado (qemu-guest-agent)."""

    def __init__(self, ruta, espera=5.0):
        super().__init__(ruta, espera)
        self.sincronizar()

    def sincronizar(self):
        # El agente pudo quedarse con media orden de una sesion anterior.
        # El byte 0xFF le reinicia el analizador JSON y guest-sync devuelve
        # el mismo numero que se le manda: se descarta todo hasta verlo.
        ident = int.from_bytes(os.urandom(4), "big") | 1
        try:
            self.s.sendall(b"\xff")
            self.enviar({"execute": "guest-sync", "arguments": {"id": ident}})
            while True:
                linea = self.recibir_linea().lstrip(b"\xff")
                try:
                    respuesta = json.loads(linea)
                except ValueError:
                    continue
                if respuesta.get("return") == ident:
                    return
        except ErrorQemu:
            raise ErrorQemu(
                "el agente del invitado no responde: la VM todavia esta arrancando "
                "o no tiene qemu-guest-agent en ejecucion"
            )

    def orden(self, nombre, **argumentos):
        mensaje = {"execute": nombre}
        if argumentos:
            mensaje["arguments"] = argumentos
        self.enviar(mensaje)
        respuesta = json.loads(self.recibir_linea().lstrip(b"\xff"))
        if "error" in respuesta:
            raise ErrorQemu(f"{nombre}: {respuesta['error'].get('desc', respuesta['error'])}")
        return respuesta.get("return")


# ----------------------------------------------------------------------------
# Ordenes QMP
# ----------------------------------------------------------------------------
def cmd_estado(a):
    q = Qmp(a.socket)
    e = q.orden("query-status")
    v = q.version
    print(f"QEMU {v['major']}.{v['minor']}.{v['micro']}  estado={e['status']}  en_ejecucion={e['running']}")
    return 0


def cmd_apagar(a):
    Qmp(a.socket).orden("system_powerdown")
    print("orden de apagado enviada (ACPI)")
    return 0


def cmd_salir(a):
    try:
        Qmp(a.socket).orden("quit")
    except ErrorQemu:
        pass                                 # QEMU cierra el socket al salir
    print("QEMU cerrado")
    return 0


def cmd_hmp(a):
    salida = Qmp(a.socket).orden("human-monitor-command", **{"command-line": " ".join(a.orden)})
    sys.stdout.write(salida)
    return 0


def cmd_capturar(a):
    """Captura el trafico de un netdev (un extremo de cable) a un archivo .pcap.

    filter-dump es un objeto de QEMU que copia cada trama que pasa por el
    backend de red, en los dos sentidos y con su etiqueta 802.1Q si la trae.
    Se crea en caliente con object-add y se quita con object-del.
    """
    archivo = os.path.abspath(a.archivo)
    os.makedirs(os.path.dirname(archivo), exist_ok=True)
    q = Qmp(a.socket)
    ident = f"cap-{a.netdev}-{os.getpid()}"
    q.orden("object-add", **{"qom-type": "filter-dump", "id": ident, "netdev": a.netdev, "file": archivo})
    print(f"capturando {a.netdev} durante {a.segundos} s (Ctrl+C para terminar antes)...")
    try:
        time.sleep(a.segundos)
    except KeyboardInterrupt:
        print()
    finally:
        q.orden("object-del", id=ident)
    tam = os.path.getsize(archivo) if os.path.exists(archivo) else 0
    aviso = "  (solo la cabecera: no paso trafico)" if tam <= 24 else ""
    print(f"captura guardada: {archivo}  ({tam} bytes){aviso}")
    return 0


# ----------------------------------------------------------------------------
# Ordenes del agente del invitado
# ----------------------------------------------------------------------------
def cmd_agente(a):
    g = Qga(a.socket)
    g.orden("guest-ping")
    info = g.orden("guest-info")
    print(f"agente del invitado OK (qemu-ga {info.get('version', '?')})")
    return 0


def cmd_exec(a):
    """Ejecuta una orden de shell como root dentro del invitado y muestra su salida."""
    orden = " ".join(a.orden)
    if not orden:
        raise ErrorQemu("falta la orden a ejecutar (despues de --)")
    g = Qga(a.socket)
    r = g.orden(
        "guest-exec",
        path="/bin/bash",
        arg=["-c", orden],
        env=[RUTA_INVITADO, "LC_ALL=C.UTF-8"],
        **{"capture-output": True},
    )
    pid = r["pid"]
    fin = time.time() + a.limite
    while True:
        estado = g.orden("guest-exec-status", pid=pid)
        if estado.get("exited"):
            break
        if time.time() > fin:
            raise ErrorQemu(f"la orden sigue en ejecucion tras {a.limite} s (PID {pid} en el invitado)")
        time.sleep(0.5)
    sys.stdout.write(base64.b64decode(estado.get("out-data", "")).decode(errors="replace"))
    sys.stderr.write(base64.b64decode(estado.get("err-data", "")).decode(errors="replace"))
    if estado.get("out-truncated") or estado.get("err-truncated"):
        sys.stderr.write("(salida truncada por el agente)\n")
    return int(estado.get("exitcode", 1))


def main():
    p = argparse.ArgumentParser(description="Control de VMs de QEMU por QMP y por el agente del invitado.")
    sub = p.add_subparsers(dest="accion", required=True)

    for nombre, funcion in (("estado", cmd_estado), ("apagar", cmd_apagar), ("salir", cmd_salir)):
        s = sub.add_parser(nombre)
        s.add_argument("socket")
        s.set_defaults(funcion=funcion)

    s = sub.add_parser("hmp")
    s.add_argument("socket")
    s.add_argument("orden", nargs="+")
    s.set_defaults(funcion=cmd_hmp)

    s = sub.add_parser("capturar")
    s.add_argument("socket")
    s.add_argument("netdev")
    s.add_argument("archivo")
    s.add_argument("--segundos", type=float, default=30)
    s.set_defaults(funcion=cmd_capturar)

    s = sub.add_parser("agente")
    s.add_argument("socket")
    s.set_defaults(funcion=cmd_agente)

    s = sub.add_parser("exec")
    s.add_argument("socket")
    s.add_argument("--limite", type=float, default=300, help="segundos maximos de espera")
    s.add_argument("orden", nargs=argparse.REMAINDER)
    s.set_defaults(funcion=cmd_exec)

    a = p.parse_args()
    if a.accion == "exec" and a.orden and a.orden[0] == "--":
        a.orden = a.orden[1:]
    try:
        return a.funcion(a)
    except ErrorQemu as e:
        print(f"qemuctl: {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
