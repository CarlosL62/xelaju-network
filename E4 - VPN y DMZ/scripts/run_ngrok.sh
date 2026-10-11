#!/usr/bin/env bash
# ==============================================================================
# run_ngrok.sh - ejecuta ngrok con su propio resolv.conf dentro de un espacio de
# montajes privado. No requiere root y nunca modifica el /etc/resolv.conf real.
#
# Por qué: E4 no tiene DHCP, y el resolvedor del equipo puede quedarse sin
# servidor upstream cuando la red del proyecto es la única salida (ngrok falla
# entonces con "lookup ...").
#
#   run_ngrok.sh [PUERTO]        levanta el túnel (PUERTO por defecto: 8081)
#   run_ngrok.sh --check         solo muestra cómo resuelve connect.ngrok-agent.com
#
# Resolvedores: config/resolv-ngrok.conf (se cambia con E4_NGROK_RESOLV).
# ==============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESOLV="$(readlink -f "${E4_NGROK_RESOLV:-$SCRIPT_DIR/../config/resolv-ngrok.conf}")"
die() { echo "ERROR: $*" >&2; exit 1; }

[ -r "$RESOLV" ] || die "no se encontró el archivo de resolvedores: $RESOLV"
command -v unshare >/dev/null 2>&1 || die "unshare no está instalado"

case "${1:-}" in
    -h|--help) sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --check)
        echo "resolvedores en el espacio privado: $(grep -c '^nameserver' "$RESOLV") (archivo: $RESOLV)"
        exec unshare -r -m bash -c 'mount --bind "$1" /etc/resolv.conf && getent ahostsv4 connect.ngrok-agent.com | head -1 | sed "s/^/connect.ngrok-agent.com -> /"' _ "$RESOLV" ;;
esac

PORT="${1:-8081}"
case "$PORT" in ''|*[!0-9]*) die "PUERTO debe ser un número" ;; esac
command -v ngrok >/dev/null 2>&1 || die "ngrok no está instalado"
exec unshare -r -m bash -c 'mount --bind "$1" /etc/resolv.conf && exec ngrok http "$2"' _ "$RESOLV" "$PORT"
