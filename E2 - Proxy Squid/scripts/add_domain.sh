#!/bin/bash
# Agrega un dominio a una lista y recarga Squid
# Uso: ./add_domain.sh <admins|users> <dominio>
LISTA=$1
DOMINIO=$2

if [ -z "$LISTA" ] || [ -z "$DOMINIO" ]; then
  echo "Uso: $0 <admins|users> <dominio>"
  exit 1
fi

case "$LISTA" in
  admins) FILE=/etc/squid/lists/admins_blacklist ;;
  users)  FILE=/etc/squid/lists/users_blacklist ;;
  *) echo "Lista invalida. Use admins o users."; exit 1 ;;
esac

echo ".$DOMINIO" >> "$FILE"
squid -k reconfigure
echo "[OK] $DOMINIO agregado a $FILE"
