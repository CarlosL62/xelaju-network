#!/usr/bin/env bash
# run_evidence.sh - Evidencias de filtrado diferenciado del proxy Squid (E2)
#
# Simula clientes de VLAN asignando IPs temporales en lo e inyectando HTTP
# que la cadena output de nftables (squid-transparent.nft) redirige a
# Squid (3129 intercept). Usa curl --resolve para no depender de DNS.
#
# Requisito: resolver hacia Squid requiere ip_forward y la salida no lo afecta,
# porque el redirect se aplica en nat OUTPUT ANTES de enrutar.
#
# Uso:   sudo ./run_evidence.sh
# Salida: líneas nuevas de /var/log/squid/access.log filtradas por las IPs simuladas.
set -u

LO_IPS="192.168.10.50 192.168.20.10 192.168.30.10 192.168.40.10"
DUMMY="10.99.99.1"   # IP falsa solo para completar el 3-way; el redirect la captura antes de rutear.

cleanup() {
    for ip in $LO_IPS; do ip addr del "$ip/32" dev lo 2>/dev/null; done
}
trap cleanup EXIT

for ip in $LO_IPS; do
    ip addr add "$ip/32" dev lo 2>/dev/null || true
done

# Marca de línea inicial para imprimir solo eventos nuevos
START=$(wc -l < /var/log/squid/access.log 2>/dev/null || echo 0)

req() { # req <src> <dominio>
    curl -s --interface "$1" --resolve "$2:80:$DUMMY" --max-time 3 -o /dev/null "http://$2/" >/dev/null 2>&1 || true
}

# VLAN 20 USERS -> users_blacklist (esperado: TCP_DENIED/403)
req 192.168.20.10 www.youtube.com
req 192.168.20.10 www.facebook.com
req 192.168.20.10 www.tiktok.com
req 192.168.20.10 www.netflix.com
# VLAN 10 ADMIN -> admins_blacklist (esperado: TCP_DENIED/403)
req 192.168.10.50 www.facebook.com
req 192.168.10.50 www.ilovepdf.com
# VLAN 30 SERVERS y VLAN 40 MGMT -> sin lista (NO debe aparecer TCP_DENIED)
req 192.168.30.10 www.youtube.com
req 192.168.40.10 www.facebook.com

sleep 1
echo "=== access.log: eventos nuevos de las IPs simuladas ==="
if [ "$START" -gt 0 ]; then
    tail -n +$((START + 1)) /var/log/squid/access.log | grep -E "192\.168\.(10|20|30|40)\.[0-9]+ " || echo "  (sin eventos nuevos)"
else
    grep -E "192\.168\.(10|20|30|40)\.[0-9]+ " /var/log/squid/access.log | tail -n 15
fi