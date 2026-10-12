#!/usr/bin/env python3
"""
XelajuNetwork - Estudiante 3: Multi-WAN, Balanceo y Failover
Script de parseo y aplicacion dinamica de politicas de salida (PBR).
Lee el archivo de politicas externo (policies.txt) y genera las reglas
de marcado de paquetes (fwmark) en nftables para conmutar por ISP1 o ISP2.
"""

import sys
import os
import re
import ipaddress
import subprocess
import datetime
import argparse

DEFAULT_POLICY_FILE = os.path.abspath(
    os.path.join(os.path.dirname(__file__), "../config/policies.txt")
)
DEFAULT_LOG_FILE = os.path.abspath(
    os.path.join(os.path.dirname(__file__), "../policies_applied.log")
)

MARK_ISP1 = "0x100"
MARK_ISP2 = "0x200"

TABLE_NAME = "xelaju_multiwan"
FAMILY = "inet"
MANGLE_CHAIN = "pbr_mangle"

def log_message(logfile, msg):
    timestamp = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    formatted = f"[{timestamp}] {msg}"
    print(formatted)
    try:
        with open(logfile, "a") as f:
            f.write(formatted + "\n")
    except Exception as e:
        print(f"Advertencia: no se pudo escribir en log: {e}", file=sys.stderr)

def parse_policies_file(filepath):
    """
    Parsea lineas con formato:
    <ip_origen>, [<puertos>], <protocolo>, <ISP_salida>
    Ejemplo:
    192.168.20.10, [80, 443], TCP, ISP1
    """
    if not os.path.isfile(filepath):
        raise FileNotFoundError(f"Archivo de politicas no encontrado: {filepath}")

    policies = []
    with open(filepath, "r", encoding="utf-8") as f:
        for line_no, raw_line in enumerate(f, start=1):
            line = raw_line.strip()
            if not line or line.startswith("#"):
                continue

            # Regex para extraer: IP, [puertos], Protocolo, ISP
            match = re.match(
                r"^([^,]+),\s*\[([^\]]+)\],\s*([A-Za-z]+),\s*([A-Za-z0-9_]+)$",
                line
            )
            if not match:
                print(f"[WARN] Linea {line_no} mal formateada, ignorando: '{line}'", file=sys.stderr)
                continue

            src_str = match.group(1).strip()
            ports_str = match.group(2).strip()
            proto_str = match.group(3).strip().upper()
            isp_str = match.group(4).strip().upper()

            # Validar IP o Subred
            try:
                ip_net = ipaddress.ip_network(src_str, strict=False)
            except ValueError:
                print(f"[WARN] Linea {line_no} IP/red invalida: '{src_str}'", file=sys.stderr)
                continue

            # Validar Puertos
            ports = []
            for p in ports_str.split(","):
                p_clean = p.strip()
                if p_clean.isdigit():
                    p_val = int(p_clean)
                    if 1 <= p_val <= 65535:
                        ports.append(p_val)
                    else:
                        print(f"[WARN] Linea {line_no} puerto fuera de rango: {p_val}", file=sys.stderr)
                else:
                    print(f"[WARN] Linea {line_no} puerto no numerico: {p_clean}", file=sys.stderr)

            if not ports:
                print(f"[WARN] Linea {line_no} sin puertos validos, ignorando.", file=sys.stderr)
                continue

            # Validar Protocolo
            if proto_str not in ["TCP", "UDP", "ANY"]:
                print(f"[WARN] Linea {line_no} protocolo desconocido: {proto_str}", file=sys.stderr)
                continue

            # Validar ISP
            if isp_str not in ["ISP1", "ISP2"]:
                print(f"[WARN] Linea {line_no} ISP desconocido: {isp_str} (esperado ISP1 o ISP2)", file=sys.stderr)
                continue

            policies.append({
                "line": line_no,
                "src": str(ip_net),
                "ports": ports,
                "proto": proto_str.lower(),
                "isp": isp_str,
                "mark": MARK_ISP1 if isp_str == "ISP1" else MARK_ISP2,
                "raw": line
            })

    return policies

def generate_nft_commands(policies):
    """
    Genera la cadena de comandos nftables para poblar pbr_mangle
    """
    cmds = []
    # Limpiar la cadena de mangle de PBR antes de poblarla
    cmds.append(f"flush chain {FAMILY} {TABLE_NAME} {MANGLE_CHAIN}")

    for pol in policies:
        src = pol["src"]
        proto = pol["proto"]
        ports_str = "{" + ", ".join(str(p) for p in pol["ports"]) + "}"
        mark = pol["mark"]
        isp = pol["isp"]

        comment = f"line_{pol['line']}_{isp}"

        if proto in ["tcp", "udp"]:
            rule = (
                f"add rule {FAMILY} {TABLE_NAME} {MANGLE_CHAIN} "
                f"ip saddr {src} {proto} dport {ports_str} "
                f"meta mark set {mark} counter comment \"{comment}\""
            )
            cmds.append(rule)
        elif proto == "any":
            # Si es any, agrega una regla para TCP y otra para UDP si hay puertos
            for p in ["tcp", "udp"]:
                rule = (
                    f"add rule {FAMILY} {TABLE_NAME} {MANGLE_CHAIN} "
                    f"ip saddr {src} {p} dport {ports_str} "
                    f"meta mark set {mark} counter comment \"{comment}\""
                )
                cmds.append(rule)

    return cmds

def apply_nft_commands(cmds, logfile):
    batch = "\n".join(cmds) + "\n"
    res = subprocess.run(["nft", "-f", "-"], input=batch, text=True, capture_output=True)
    if res.returncode != 0:
        log_message(logfile, f"[ERROR] Fallo al aplicar reglas en nftables: {res.stderr}")
        return False
    return True

def main():
    parser = argparse.ArgumentParser(description="Aplicador de politicas PBR para Multi-WAN (E3)")
    parser.add_argument("--config", default=DEFAULT_POLICY_FILE, help="Ruta al archivo policies.txt")
    parser.add_argument("--log", default=DEFAULT_LOG_FILE, help="Ruta al archivo de log")
    parser.add_argument("--dry-run", action="store_true", help="Solo parsear e imprimir reglas sin aplicar")
    args = parser.parse_args()

    log_message(args.log, f"Iniciando lectura de politicas desde {args.config}...")

    try:
        policies = parse_policies_file(args.config)
    except Exception as e:
        log_message(args.log, f"[ERROR] Error critico leyendo archivo de politicas: {e}")
        sys.exit(1)

    log_message(args.log, f"Se cargaron {len(policies)} politicas validas.")

    cmds = generate_nft_commands(policies)

    if args.dry_run:
        print("\n=== COMANDOS NFTABLES GENERADOS (DRY-RUN) ===")
        for c in cmds:
            print(c)
        print("=============================================\n")
        return

    # Verificar si nftables tiene la tabla y cadena base
    check_table = subprocess.run(["nft", "list", "chain", FAMILY, TABLE_NAME, MANGLE_CHAIN],
                                 capture_output=True, text=True)
    if check_table.returncode != 0:
        log_message(args.log, f"[WARN] La tabla/cadena '{TABLE_NAME} {MANGLE_CHAIN}' no existe. Creandola...")
        setup_cmds = [
            f"add table {FAMILY} {TABLE_NAME}",
            f"add chain {FAMILY} {TABLE_NAME} {MANGLE_CHAIN}"
        ]
        if not apply_nft_commands(setup_cmds, args.log):
            log_message(args.log, "[ERROR] No se pudo crear la cadena pbr_mangle en nftables.")
            sys.exit(1)

    if apply_nft_commands(cmds, args.log):
        log_message(args.log, f"[SUCCESS] Se aplicaron exitosamente {len(policies)} politicas en nftables.")
        for p in policies:
            log_message(args.log, f"  -> Politica: Origen={p['src']} Puertos={p['ports']} Proto={p['proto'].upper()} ==> {p['isp']} (Mark {p['mark']})")
    else:
        log_message(args.log, "[ERROR] Hubo un error al ejecutar los comandos en nftables.")
        sys.exit(1)

if __name__ == "__main__":
    main()
