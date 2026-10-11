#!/usr/bin/env python3
"""isp-panel.py - panel en vivo del registro que escribe grupal/isp-activo.sh

Se ejecuta en el HOST (no dentro de las VMs) y sin root:

    ./grupal/isp-panel.py               sigue el registro mas reciente
    ./grupal/isp-panel.py <registro>    sigue ese archivo
    ./grupal/isp-panel.py --una-vez     lo dibuja una vez y termina

No mide nada: lee evidencias/consola/isp-activo-AAAAMMDD.log (una linea por
ciclo) y lo presenta como una tabla con colores: por cual ISP de E3 sale cada
VLAN, si la conexion real funciono, los ultimos ciclos de cada clase y los
cambios de estado. El monitor tiene que estar en marcha dentro de R1-LAN (ver
la cabecera de isp-activo.sh); si se detiene, el panel lo avisa.

Opciones:  --sin-color   sin colores      --ascii   sin simbolos Unicode
Solo biblioteca estandar.
"""

import argparse
import collections
import datetime
import re
import signal
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
DIR_REGISTROS = REPO / "evidencias/consola"
CICLOS_VISIBLES = 20        # ciclos que muestra la barra de cada clase
EVENTOS_VISIBLES = 6

LINEA = re.compile(r"^(\d{4}-\d\d-\d\d) (\d\d:\d\d:\d\d) (\S+) ?(.*)$")
CLASE = re.compile(r"(\S+?)/(tcp|udp)(\d+)=([^,]+),(\S+)")

# Lo que significa cada estado de isp-activo.sh y con que color se pinta
ESTADOS = {
    "NORMAL":        ("verde",    "los dos ISP activos"),
    "SOLO-ISP1":     ("amarillo", "ISP2 caido: todo sale por ISP1 (failover de E3)"),
    "SOLO-ISP2":     ("amarillo", "ISP1 caido: todo sale por ISP2 (failover de E3)"),
    "PARCIAL":       ("amarillo", "una referencia sin respuesta o sin ruta en E3"),
    "UN-SOLO-ISP":   ("amarillo", "todo sale por un ISP que no se pudo identificar"),
    "SIN-SALIDA":    ("rojo",     "E3 contesta que no tiene ruta a Internet"),
    "SIN-RESPUESTA": ("rojo",     "no responde ninguna puerta de salida"),
    "SIN-CAMINO":    ("rojo",     "E3 no aparece en el camino: revisar E2 y E5"),
}
TRAFICO = {"tcp443": "WEB  tcp/443", "udp53": "DNS  udp/53"}
ANSI = {"verde": "32", "amarillo": "33", "rojo": "31", "isp1": "36", "isp2": "35",
        "gris": "90", "negrita": "1"}


class Panel:
    def __init__(self, color, ascii_):
        self.color = color
        s = ("*", "ok", "X", "#", ".", "->") if ascii_ else ("\u25cf", "\u2713", "\u2717", "\u2588", "\u00b7", "\u2192")
        self.punto, self.bien, self.mal, self.bloque, self.hueco, self.flecha = s
        self.intervalo = 10
        self.momento = None             # fecha y hora del ultimo ciclo
        self.estado = None
        self.isp1 = self.isp2 = "-"
        self.actual = {}                # (origen, trafico) -> (isp, extremo)
        self.historia = collections.defaultdict(lambda: collections.deque(maxlen=CICLOS_VISIBLES))
        self.origenes, self.traficos = [], []
        self.eventos = collections.deque(maxlen=EVENTOS_VISIBLES)
        self.detenido = None            # hora del FIN, si el monitor se detuvo

    # ---- Lectura del registro ----------------------------------------------------
    def procesar(self, linea):
        m = LINEA.match(linea.strip())
        if not m:
            return
        fecha, hora, tipo, resto = m.groups()
        if tipo == "INICIO":
            self.detenido = None
            i = re.search(r"intervalo=(\d+)s", resto)
            if i:
                self.intervalo = int(i.group(1))
        elif tipo == "FIN":
            self.detenido = hora
        elif tipo == "EVENTO":
            cambio = re.match(r"estado (\S+) -> (\S+)", resto)
            if cambio:
                antes, ahora = cambio.groups()
                self.eventos.append((hora, ahora, f"{antes} {self.flecha} {ahora}", ESTADOS.get(ahora, ("", ""))[1]))
            else:
                self.eventos.append((hora, None, re.sub(r" de las referencias", "", resto), ""))
        elif tipo in ESTADOS:
            self.detenido = None
            self.momento = datetime.datetime.strptime(f"{fecha} {hora}", "%Y-%m-%d %H:%M:%S")
            self.estado = tipo
            puertas = dict(re.findall(r"(isp[12])=(\S+)", resto))
            self.isp1, self.isp2 = puertas.get("isp1", self.isp1), puertas.get("isp2", self.isp2)
            vistas = set()
            for origen, proto, puerto, isp, extremo in CLASE.findall(resto):
                clave = (origen, proto + puerto)
                if origen not in self.origenes:
                    self.origenes.append(origen)
                if clave[1] not in self.traficos:
                    self.traficos.append(clave[1])
                self.actual[clave] = (isp, extremo)
                self.historia[clave].append((isp, extremo))
                vistas.add(clave)
            for clave in self.actual:            # ciclo sin sondas (SIN-CAMINO)
                if clave not in vistas:
                    self.actual[clave] = ("-", "-")
                    self.historia[clave].append(("-", "-"))

    # ---- Dibujo ------------------------------------------------------------------
    def c(self, texto, *estilos):
        if not self.color or not estilos:
            return texto
        return f"\033[{';'.join(ANSI[e] for e in estilos)}m{texto}\033[0m"

    def etiqueta_isp(self, isp):
        """Texto de 9 columnas y su color para el ISP de una sonda."""
        if isp in ("ISP1", "ISP2"):
            return self.c(f"{isp:<9}", isp.lower(), "negrita")
        if isp == "SIN-RESP":
            return self.c(f"{'sin resp.':<9}", "gris")
        if isp == "SIN-RUTA":
            return self.c(f"{'sin ruta':<9}", "rojo")
        if isp.startswith("ISP?"):
            return self.c(f"{'ISP ?':<9}", "amarillo")
        return self.c(f"{'-':<9}", "gris")

    def marca(self, extremo):
        if extremo == "OK":
            return self.c(f"{self.bien:<2}", "verde")
        if extremo == "FALLA":
            return self.c(f"{self.mal:<2}", "rojo", "negrita")
        return self.c(f"{'-':<2}", "gris")

    def barra(self, clave):
        trozos = []
        for isp, extremo in self.historia[clave]:
            if extremo == "FALLA":
                trozos.append(self.c(self.bloque, "rojo"))
            elif isp in ("ISP1", "ISP2"):
                trozos.append(self.c(self.bloque, isp.lower()))
            else:
                trozos.append(self.c(self.hueco, "gris"))
        return "".join(trozos) + " " * (CICLOS_VISIBLES - len(self.historia[clave]))

    def frescura(self):
        if self.detenido:
            return self.c(f"monitor detenido a las {self.detenido}", "amarillo", "negrita")
        edad = int((datetime.datetime.now() - self.momento).total_seconds())
        if edad > max(3 * self.intervalo, 30):
            return self.c(f"SIN DATOS desde hace {hace(edad)}: sigue en marcha el monitor?", "rojo", "negrita")
        return self.c(f"actualizado hace {max(edad, 0)} s", "gris")

    def lineas(self, registro):
        if self.estado is None:
            return ["", f"  {registro}: todavia no tiene ningun ciclo completo.", ""]
        color, texto = ESTADOS[self.estado]
        hora = self.momento.strftime("%H:%M:%S")
        salida = [
            "",
            "  " + self.c("XelajuNetwork", "negrita") + "  ISP en uso (Multi-WAN de E3)" + " " * 21 + self.c(hora, "negrita"),
            "",
            "  " + self.c(f"{self.punto} {self.estado}", color, "negrita") + f"  {texto}",
            "  " + self.frescura(),
            "",
            "  " + self.c("ISP1", "isp1", "negrita") + f"  Wi-Fi de E3  {self.isp1:<18}"
                 + self.c("ISP2", "isp2", "negrita") + f"  celular  {self.isp2}",
            "",
            "  " + self.c(f"{'ORIGEN':<12}" + "".join(f"{TRAFICO.get(t, t):<34}" for t in self.traficos).rstrip(), "gris"),
        ]
        for origen in self.origenes:
            fila = "  " + self.c(f"{origen:<12}", "negrita")
            for trafico in self.traficos:
                isp, extremo = self.actual.get((origen, trafico), ("-", "-"))
                fila += self.etiqueta_isp(isp) + self.marca(extremo) + self.barra((origen, trafico)) + "   "
            salida.append(fila.rstrip())
        salida += [
            "",
            "  " + self.c(f"Ultimos {CICLOS_VISIBLES} ciclos:  ", "gris") + self.c(self.bloque, "isp1") + " ISP1   "
                 + self.c(self.bloque, "isp2") + " ISP2   " + self.c(self.bloque, "rojo") + " la conexion fallo   "
                 + self.c(self.hueco, "gris") + " sin respuesta",
            "",
            "  " + self.c("Ultimos cambios", "negrita"),
        ]
        if not self.eventos:
            salida.append("  " + self.c("ninguno desde que empezo el registro", "gris"))
        for hora_ev, estado_ev, texto_ev, detalle in self.eventos:
            color_ev = (ESTADOS[estado_ev][0],) if estado_ev in ESTADOS else ()
            salida.append("  " + self.c(hora_ev, "gris") + "  " + self.c(f"{texto_ev:<26}", *color_ev)
                          + ("  " + self.c(detalle, "gris") if detalle else ""))
        salida += ["", "  " + self.c(f"Registro: {registro}", "gris")]
        return salida


def hace(segundos):
    """Una duracion en la unidad que mejor se lee."""
    for limite, divisor, unidad in ((120, 1, "s"), (7200, 60, "min"), (172800, 3600, "h")):
        if segundos < limite:
            return f"{segundos // divisor} {unidad}"
    return f"{segundos // 86400} dias"


def registro_mas_reciente():
    candidatos = sorted(DIR_REGISTROS.glob("isp-activo-*.log"), key=lambda p: p.stat().st_mtime)
    return candidatos[-1] if candidatos else None


def mostrar_ruta(ruta):
    try:
        return str(ruta.resolve().relative_to(REPO))
    except ValueError:
        return str(ruta)


def main():
    p = argparse.ArgumentParser(description="Panel en vivo del registro de grupal/isp-activo.sh (se ejecuta en el host).")
    p.add_argument("registro", nargs="?", help="archivo a seguir (por omision, el mas reciente de evidencias/consola/)")
    p.add_argument("--una-vez", action="store_true", help="dibuja el estado actual y termina")
    p.add_argument("--sin-color", action="store_true")
    p.add_argument("--ascii", action="store_true", help="sin simbolos Unicode")
    a = p.parse_args()

    ruta = Path(a.registro) if a.registro else registro_mas_reciente()
    if ruta is None or not ruta.exists():
        print("isp-panel.py: no hay ningun registro de isp-activo.sh. Arranca el monitor dentro de R1-LAN:\n"
              "  ./lab/lab.sh exec r1-lan 'setsid nohup /mnt/proyecto/grupal/isp-activo.sh >/dev/null 2>&1 &'",
              file=sys.stderr)
        return 1

    en_vivo = sys.stdout.isatty() and not a.una_vez
    utf8 = "utf" in (sys.stdout.encoding or "").lower()
    panel = Panel(color=not a.sin_color and (sys.stdout.isatty() or a.una_vez), ascii_=a.ascii or not utf8)
    nombre = mostrar_ruta(ruta)

    with open(ruta, errors="replace") as f:
        for linea in f:
            panel.procesar(linea)
        if not en_vivo:
            print("\n".join(panel.lineas(nombre)))
            return 0

        pendiente = ""
        signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(KeyboardInterrupt()))  # devuelve el cursor tambien con kill
        sys.stdout.write("\033[?25l\033[2J")            # oculta el cursor y limpia la pantalla
        try:
            while True:
                trozo = f.readline()
                if trozo:
                    pendiente += trozo
                    if pendiente.endswith("\n"):        # solo lineas completas
                        panel.procesar(pendiente)
                        pendiente = ""
                    continue
                cuerpo = panel.lineas(nombre) + ["  " + panel.c("Ctrl+C para salir (el monitor sigue en marcha)", "gris")]
                sys.stdout.write("\033[H" + "".join(l + "\033[K\n" for l in cuerpo) + "\033[J")
                sys.stdout.flush()
                time.sleep(1)
        except KeyboardInterrupt:
            pass
        finally:
            sys.stdout.write("\033[?25h\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
