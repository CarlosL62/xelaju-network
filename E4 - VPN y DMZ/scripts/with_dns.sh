#!/usr/bin/env bash
# ==============================================================================
# with_dns.sh - ejecuta un comando (o una shell interactiva) con los resolvedores
# DNS del proyecto, dentro de un espacio de montajes privado. No requiere root y
# el /etc/resolv.conf real nunca se modifica, de modo que lo que lo administre
# (p. ej. NetworkManager) sigue funcionando intacto. Al salir del comando o de la
# shell termina el cambio.
#
#   with_dns.sh                       shell interactiva con el DNS del proyecto
#   with_dns.sh curl -I https://example.com
#   with_dns.sh getent hosts example.com
#
# Resolvedores: config/resolv-ngrok.conf (se cambia con E4_DNS_RESOLV).
# Alcance: solo los procesos iniciados dentro. Los demonios que ya corren conservan
# el DNS anterior, y las herramientas que necesitan root real (apt) no sirven aquí:
# el root de este espacio es el propio usuario mapeado a uid 0.
# ==============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESOLV="$(readlink -f "${E4_DNS_RESOLV:-$SCRIPT_DIR/../config/resolv-ngrok.conf}")"
[ -r "$RESOLV" ] || { echo "ERROR: no se encontró el archivo de resolvedores: $RESOLV" >&2; exit 1; }
command -v unshare >/dev/null 2>&1 || { echo "ERROR: unshare no está instalado" >&2; exit 1; }
case "${1:-}" in -h|--help) sed -n '2,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;; esac

if [ $# -eq 0 ]; then
    echo "DNS del proyecto activo en esta shell ($(grep '^nameserver' "$RESOLV" | awk '{print $2}' | paste -sd' ')). Escriba 'exit' para salir." >&2
    set -- "${SHELL:-/bin/bash}"
fi
exec unshare -r -m bash -c 'mount --bind "$1" /etc/resolv.conf && shift && exec "$@"' _ "$RESOLV" "$@"
