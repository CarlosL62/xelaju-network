#!/bin/bash
# Validacion basica de la configuracion del nodo E2 (no destructivo)
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FAIL=0

ok()  { echo "[OK]   $1"; }
bad() { echo "[FAIL] $1"; FAIL=1; }

# 1. Archivos requeridos
for f in config/squid.conf config/squid-transparent.nft config/squid.env \
         config/lists/admins_blacklist config/lists/users_blacklist \
         scripts/install.sh portal/app.py; do
  [ -f "$ROOT/$f" ] && ok "existe $f" || bad "falta $f"
done

# 2. Directivas criticas en squid.conf
grep -q "http_port 3129 intercept" "$ROOT/config/squid.conf" \
  && ok "modo intercept/transparente definido" || bad "falta puerto intercept"
grep -q "admin_blacklist" "$ROOT/config/squid.conf" \
  && ok "ACL admin_blacklist definida" || bad "falta admin_blacklist"
grep -q "users_blacklist" "$ROOT/config/squid.conf" \
  && ok "ACL users_blacklist definida" || bad "falta users_blacklist"
grep -q "access_log" "$ROOT/config/squid.conf" \
  && ok "access_log configurado" || bad "falta access_log"

# 3. Las listas deben tener dominios
[ "$(grep -cv '^\s*#\|^\s*$' "$ROOT/config/lists/admins_blacklist")" -ge 1 ] \
  && ok "admins_blacklist con dominios" || bad "admins_blacklist vacia"
[ "$(grep -cv '^\s*#\|^\s*$' "$ROOT/config/lists/users_blacklist")" -ge 1 ] \
  && ok "users_blacklist con dominios" || bad "users_blacklist vacia"

# 4. Sintaxis Python del portal
python3 -m py_compile "$ROOT/portal/app.py" && ok "portal/app.py compila" || bad "app.py con errores"

# 5. Sintaxis bash de scripts
for s in "$ROOT"/scripts/*.sh; do
  bash -n "$s" && ok "sintaxis $(basename "$s")" || bad "error en $(basename "$s")"
done

echo ""
[ $FAIL -eq 0 ] && echo "VALIDACION OK" || echo "VALIDACION CON ERRORES"
exit $FAIL
