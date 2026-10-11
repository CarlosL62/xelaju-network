#!/usr/bin/env python3
"""
Portal de consulta de logs de Squid - Estudiante 2
Solo accesible desde VLAN ADMIN (restringir con firewall).
Ejecutar: python3 app.py
"""
import ipaddress
import re
from datetime import datetime
from flask import Flask, abort, render_template_string, request

LOG_FILE = "/var/log/squid/access.log"
app = Flask(__name__)

# Redes autorizadas para consultar el portal (restringido a VLAN ADMIN según especificación):
# El enlace de tránsito E1-E2 (192.168.84.0/30) se retiró en la validación final:
# la especificación exige acceso EXCLUSIVO desde VLAN ADMIN.
ALLOWED_NETWORKS = [
    ipaddress.ip_network("192.168.10.0/24"),  # VLAN 10 ADMIN (única red autorizada)
    ipaddress.ip_network("127.0.0.0/8"),      # Localhost (mantenimiento/diagnóstico en E2)
]

@app.before_request
def restrict_admin_access():
    client_ip_str = request.remote_addr
    try:
        client_ip = ipaddress.ip_address(client_ip_str)
        if not any(client_ip in net for net in ALLOWED_NETWORKS):
            abort(403, description=f"Acceso denegado: IP {client_ip_str} no autorizada. El portal está restringido exclusivamente a la VLAN ADMIN (192.168.10.0/24).")
    except ValueError:
        abort(403, description="Dirección IP de cliente no válida.")

@app.errorhandler(403)
def forbidden(e):
    return f"""<!doctype html><html><head><meta charset="utf-8"><title>403 Prohibido</title>
<style>body{{font-family:Arial,sans-serif;margin:40px;background:#fde8e8;color:#c0392b}}
.card{{background:#fff;padding:20px;border-radius:6px;box-shadow:0 1px 3px rgba(0,0,0,.1)}}
</style></head><body><div class="card"><h2>403 - Acceso Denegado</h2>
<p>{e.description}</p><hr><small>XelajuNetwork - E2 Proxy Squid (Seguridad y Auditoría)</small></div>
</body></html>""", 403

LINE = re.compile(
    r'^(?P<ts>\d+\.\d+)\s+(?P<elapsed>\d+)\s+(?P<client>[\d\.]+)\s+'
    r'(?P<result>[A-Z_]+/\d+)\s+(?P<bytes>\d+)\s+(?P<method>\w+)\s+'
    r'(?P<url>\S+)\s+(?P<ident>\S+)\s+(?P<hier>\S+)'
)

HTML = """
<!doctype html><html><head><meta charset="utf-8">
<title>Portal Proxy - XelajuNetwork</title>
<style>
 body{font-family:Arial,sans-serif;margin:20px;background:#f4f6f8}
 h1{color:#1a3c5e} table{border-collapse:collapse;width:100%;background:#fff}
 th,td{border:1px solid #ccc;padding:6px 10px;font-size:13px}
 th{background:#1a3c5e;color:#fff} tr:nth-child(even){background:#eef3f8}
 .ok{color:green;font-weight:bold}.bad{color:#c0392b;font-weight:bold}
 form{margin-bottom:15px} input{padding:5px} button{padding:5px 12px}
 .stats{display:flex;gap:20px;margin-bottom:15px}
 .card{background:#fff;padding:15px;border-radius:6px;box-shadow:0 1px 3px rgba(0,0,0,.1)}
</style></head><body>
<h1>Portal de Consulta - Proxy Squid</h1>
<div class="stats">
  <div class="card"><b>Total solicitudes:</b> {{ total }}</div>
  <div class="card"><b>Permitidas:</b> <span class="ok">{{ allowed }}</span></div>
  <div class="card"><b>Bloqueadas:</b> <span class="bad">{{ denied }}</span></div>
</div>
<form method="get">
  <input name="ip" placeholder="Filtrar por IP origen" value="{{ ip }}">
  <input name="dom" placeholder="Filtrar por dominio" value="{{ dom }}">
  <button>Filtrar</button>
</form>
<table><tr><th>Fecha/Hora</th><th>IP Origen</th><th>Resultado</th><th>Metodo</th><th>Dominio/URL</th><th>Bytes</th></tr>
{% for r in rows %}
<tr><td>{{ r.fecha }}</td><td>{{ r.client }}</td>
<td class="{{ 'bad' if 'DENIED' in r.result or r.result.endswith('/403') else 'ok' }}">{{ r.result }}</td>
<td>{{ r.method }}</td><td>{{ r.url }}</td><td>{{ r.bytes }}</td></tr>
{% endfor %}
</table>
</body></html>
"""


def parse_log():
    rows = []
    try:
        with open(LOG_FILE, errors="ignore") as f:
            for line in f:
                m = LINE.match(line)
                if not m:
                    continue
                d = m.groupdict()
                d["fecha"] = datetime.fromtimestamp(float(d["ts"])).strftime("%Y-%m-%d %H:%M:%S")
                rows.append(d)
    except (FileNotFoundError, PermissionError):
        pass
    return rows


@app.route("/")
def index():
    ip = request.args.get("ip", "").strip()
    dom = request.args.get("dom", "").strip().lower()
    rows = parse_log()
    if ip:
        rows = [r for r in rows if r["client"].startswith(ip)]
    if dom:
        rows = [r for r in rows if dom in r["url"].lower()]
    denied = sum(1 for r in rows if "DENIED" in r["result"] or r["result"].endswith("/403"))
    return render_template_string(
        HTML, rows=rows[-200:], total=len(rows),
        allowed=len(rows) - denied, denied=denied, ip=ip, dom=dom,
    )


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
