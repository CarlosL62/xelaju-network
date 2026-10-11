#!/bin/bash
# Instalacion automatica del proxy Squid transparente (Debian)
# Alineado con plan de direccionamiento core/ADDRESSING.yaml (PR #4)
set -e

echo "[1/6] Instalando Squid y Flask..."
apt-get update
apt-get install -y squid python3-flask

echo "[2/6] Creando directorios..."
mkdir -p /etc/squid/lists
mkdir -p /var/log/squid

echo "[3/6] Copiando configuracion..."
cp config/squid.conf /etc/squid/squid.conf
cp config/squid.env /etc/squid/squid.env 2>/dev/null || true
cp config/lists/admins_blacklist /etc/squid/lists/
cp config/lists/users_blacklist /etc/squid/lists/

echo "[4/6] Habilitando IP forwarding (E2 es router transit entre E1 y E5)"
sysctl -w net.ipv4.ip_forward=1
echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.d/99-squid-transit.conf

echo "[4b/6] Agregando rutas estáticas hacia VLANs (transit E1)..."
# Rutas hacia LAN_VLANS via R1 (192.168.84.2) - según routing_plan.E2_squid
ip route replace 192.168.10.0/24 via 192.168.84.2 2>/dev/null || true
ip route replace 192.168.20.0/24 via 192.168.84.2 2>/dev/null || true
ip route replace 192.168.30.0/24 via 192.168.84.2 2>/dev/null || true
ip route replace 192.168.40.0/24 via 192.168.84.2 2>/dev/null || true

echo "[5/6] Aplicando reglas de redireccion transparente (nftables)..."
mkdir -p /etc/nftables.d
cp config/squid-transparent.nft /etc/nftables.d/
# Validar sintaxis ANTES de aplicar (evita cargar reglas rotas de forma silenciosa)
if ! nft -c -f /etc/nftables.d/squid-transparent.nft; then
    echo "ERROR: sintaxis nftables invalida. Reglas NO aplicadas." >&2
    exit 1
fi
nft -f /etc/nftables.d/squid-transparent.nft || { echo "ERROR: no se pudieron aplicar las reglas nftables" >&2; exit 1; }
# Verificar que la tabla quedo realmente cargada
if ! nft list table ip squid_transparent >/dev/null 2>&1; then
    echo "ERROR: la tabla ip squid_transparent no quedo cargada" >&2
    exit 1
fi
echo "  nftables: tabla ip squid_transparent cargada [OK]"

echo "[5b/6] Asegurando persistencia de nftables al reiniciar..."
if [ -f /etc/nftables.conf ]; then
    if ! grep -q "squid-transparent.nft" /etc/nftables.conf; then
        echo 'include "/etc/nftables.d/squid-transparent.nft"' >> /etc/nftables.conf
    fi
fi
systemctl enable nftables 2>/dev/null || true

echo "[6/6] Ajustando permisos, cache e iniciando Squid..."
squid -z 2>/dev/null || true
chown -R proxy:proxy /var/log/squid /var/spool/squid
chmod 755 /var/log/squid
touch /var/log/squid/access.log
chmod 644 /var/log/squid/access.log
cp config/squid-logrotate /etc/logrotate.d/squid

ACTUAL_USER="${SUDO_USER:-carlos}"
if id "$ACTUAL_USER" >/dev/null 2>&1; then
    usermod -aG proxy "$ACTUAL_USER" 2>/dev/null || true
fi

systemctl enable squid
systemctl restart squid

echo "[6b/6] Configurando servicio systemd para el portal de administración..."
PORTAL_DIR="$(cd "$(dirname "$0")/../portal" && pwd)"
cat <<EOF > /etc/systemd/system/squid-portal.service
[Unit]
Description=Portal Web de Logs de Squid - Estudiante 2
After=network.target squid.service

[Service]
Type=simple
User=${ACTUAL_USER}
Group=proxy
WorkingDirectory=${PORTAL_DIR}
ExecStart=/usr/bin/python3 app.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now squid-portal.service


echo ""
echo "Instalacion completa."
echo "Portal: cd portal && python3 app.py  -> http://<IP-PROXY>:8080"
echo "Ver logs: tail -f /var/log/squid/access.log"
echo "Recargar listas: ./scripts/reload.sh"
