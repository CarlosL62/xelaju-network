#!/bin/bash
# nodos/pc-admin01/escritorio.sh - instala el escritorio (XFCE + Firefox ESR) en PC-ADMIN01
# Uso, dentro de la VM, despues de aplicar.sh:   sudo /mnt/proyecto/nodos/pc-admin01/escritorio.sh
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../_comun/escritorio.sh" "$@"
