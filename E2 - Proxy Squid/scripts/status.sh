#!/bin/bash
# ==============================================================================
# status.sh - Diagnóstico y estado del nodo E2 (Squid Proxy Transparente)
# XelajuNetwork - Estudiante 2
# ==============================================================================
set -u

echo "============================================================"
echo " ESTADO DEL NODO E2 (Squid Proxy Transparente)"
echo "============================================================"

# 1. IP Forwarding
echo -n "[1] IPv4 Forwarding: "
FORWARD=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || /sbin/sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)
if [ "$FORWARD" -eq 1 ]; then
    echo "ACTIVO (1) [OK]"
else
    echo "INACTIVO ($FORWARD) [AVISO - Ejecutar sysctl -w net.ipv4.ip_forward=1]"
fi

# 2. Direccionamiento IP
echo ""
echo "[2] Interfaces y Direcciones IP:"
ip -br addr show | grep -v "lo" || echo "No hay interfaces activas"
echo "  - Esperado hacia E1 (downstream): 192.168.84.1/30"
echo "  - Esperado hacia E5 (upstream):   192.168.82.2/30"

# 3. Rutas de retorno hacia VLANs y Default
echo ""
echo "[3] Rutas estáticas de retorno (LAN_VLANS via E1):"
for vlan in 192.168.10.0/24 192.168.20.0/24 192.168.30.0/24 192.168.40.0/24; do
    if ip route show "$vlan" 2>/dev/null | grep -q "192.168.84.2"; then
        echo "  - $vlan via 192.168.84.2 [OK]"
    else
        echo "  - $vlan [FALTA RUTA via 192.168.84.2]"
    fi
done

echo "[3b] Rutas por defecto activas:"
ip route show default 2>/dev/null | while read -r line; do
    echo "  - $line"
done


# 4. Servicio Squid
echo ""
echo "[4] Servicio Squid:"
if systemctl is-active --quiet squid 2>/dev/null; then
    echo "  - Estado systemd: ACTIVO (running) [OK]"
elif pgrep -x squid >/dev/null 2>&1; then
    echo "  - Proceso squid: ACTIVO [OK]"
else
    echo "  - Estado: DETENIDO o no instalado [AVISO]"
fi

for port in 3128 3129; do
    if ss -tln 2>/dev/null | grep -qE "(:$port|\*:$port)\b"; then
        echo "  - Puerto $port en escucha: [OK]"
    else
        echo "  - Puerto $port: NO escuchando [AVISO]"
    fi
done

# 5. Reglas nftables (redirección transparente)
echo ""
echo "[5] Redirección transparente (nftables):"
if /usr/sbin/nft list table ip squid_transparent >/dev/null 2>&1 || sudo -n /usr/sbin/nft list table ip squid_transparent >/dev/null 2>&1; then
    echo "  - Tabla ip squid_transparent: CARGADA [OK]"
else
    echo "  - Tabla ip squid_transparent: NO ENCONTRADA o no cargada [AVISO]"
fi



# 6. Portal Web de Logs (Puerto 8080)
echo ""
echo "[6] Portal Web de Logs (Flask):"
if ss -tlnp 2>/dev/null | grep -q ":8080 "; then
    echo "  - Puerto 8080 en escucha: ACTIVO [OK]"
else
    echo "  - Puerto 8080: INACTIVO (ejecutar: cd portal && python3 app.py &)"
fi

# 7. Listas de bloqueo
echo ""
echo "[7] Listas de bloqueo externas:"
for f in /etc/squid/lists/admins_blacklist /etc/squid/lists/users_blacklist; do
    if [ -f "$f" ]; then
        COUNT=$(grep -cv '^\s*#\|^\s*$' "$f" 2>/dev/null || echo 0)
        echo "  - $(basename "$f"): $COUNT dominios registrados [OK]"
    else
        echo "  - $(basename "$f"): NO EXISTE en /etc/squid/lists/ [AVISO]"
    fi
done

echo ""
echo "============================================================"
