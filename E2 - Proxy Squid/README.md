# Estudiante 2 — Proxy Squid Transparente (E2)

**Responsable:** Estudiante 2
**Entrega:** 13 de octubre de 2026 — 15:20 (Classroom)
**Sistema:** Debian GNU/Linux (modo consola / texto)
**Rol:** Control y filtrado del tráfico Web mediante Squid en modo **transparente**, con políticas diferenciadas por VLAN, registro/consulta de solicitudes y portal administrativo restringido a la VLAN ADMIN.

---

## 1. Qué implementa (enunciado, sección 5)

| Requisito | Implementación |
|---|---|
| Squid | Sí — proxy transparente |
| Proxy en modo transparente | `http_port 3129 intercept` (+ `3128` explícito como respaldo) |
| Intercepción de tráfico HTTP | nftables redirige TCP 80 a Squid; sin proxy manual en clientes |
| Filtrado de dominios por archivos independientes | `config/lists/admins_blacklist` y `config/lists/users_blacklist` |
| Políticas diferenciadas ADMIN / USERS | ACL de Squid por red de origen (`192.168.10.0/24` vs `192.168.20.0/24`) |
| Registro de solicitudes | `/var/log/squid/access.log` (IP origen, fecha/hora, dominio, método, resultado) |
| Administración y consulta de logs | Portal web `http://192.168.84.1:8080` (solo VLAN ADMIN) |
| Pruebas de navegación permitida y bloqueada | `test/run_evidence.sh` + evidencias en `evidencias/` |
| Tráfico no Web (HTTPS, DNS, etc.) | Atraviesa E2 como router puro (`ip_forward=1`), sin intercepción |

## 2. Topología de E2

```text
LAN_VLANS ──[E1: 192.168.84.2] ──(192.168.84.0/30)── [192.168.84.1: E2]
                                                           │
                                              (Squid intercept / transit)
                                                           │
Internet ◄─[E3 Multi-WAN] ◄─[E5: 192.168.82.1] ◄─(192.168.82.0/30)── [192.168.82.2: E2]
```

- **Hacia E1 (LAN):** `192.168.84.1/30`, rutas a las VLAN `192.168.10/20/30/40.0/24` vía `192.168.84.2`.
- **Hacia E5 (perímetro):** `192.168.82.2/30`, ruta por defecto vía `192.168.82.1`.
- **IP forwarding:** `net.ipv4.ip_forward = 1` (persistente en sysctl).
- **No procesa:** HTTPS (443), DNS (53), VLAN VPN (`10.200.0.0/16`), DMZ (`172.16.10.0/24`): tránsito puro.

## 3. Filtrado por VLAN

| Red de origen | VLAN | Lista | Comportamiento |
|---|---|---|---|
| `192.168.10.0/24` | 10 ADMIN | `admins_blacklist` | Bloquea `facebook.com`, `ilovepdf.com`, etc.; resto permitido |
| `192.168.20.0/24` | 20 USERS | `users_blacklist` | Bloquea `youtube.com`, `tiktok.com`, `facebook.com`, etc.; resto permitido |
| `192.168.30.0/24` | 30 SERVIDORES | — | Sin lista (no denegado) |
| `192.168.40.0/24` | 40 GESTIÓN | — | Sin lista (no denegado) |

Las listas se modifican **en caliente** (durante la calificación) sin reescribir `squid.conf`:

```bash
# Manual:
echo ".nuevo-bloqueo.com" | sudo tee -a /etc/squid/lists/users_blacklist
sudo squid -k reconfigure

# Con el script de ayuda (recomendado):
sudo ./scripts/add_domain.sh users nuevo-bloqueo.com      # agrega
sudo ./scripts/remove_domain.sh users nuevo-bloqueo.com   # elimina
```

## 4. Portal de administración (puerto 8080)

- **URL:** `http://192.168.84.1:8080`
- **Restricción:** accesible **únicamente desde la VLAN ADMIN** (`192.168.10.0/24` y loopback). Cualquier otro origen recibe `403`.
  - Aplicación (`portal/app.py`): `ALLOWED_NETWORKS = [192.168.10.0/24, 127.0.0.0/8]`.
  - Refuerzo en nftables (`squid-transparent.nft`): `tcp dport 8080 ip saddr != 192.168.10.0/24 drop`.
- **Contenido:** solicitudes procesadas, dominios solicitados, IP de origen, permitido/bloqueado, fecha/hora y estadísticas básicas.

## 5. Registros

`/var/log/squid/access.log` permite analizar por línea:

- **IP origen** · **fecha/hora** · **dominio/destino** · **método** · **resultado** (ej. `TCP_DENIED/403`, `TCP_MISS/200`).

## 6. Instalación y puesta en marcha (Debian, consola)

```bash
# 1. Validar configuración (no destructivo)
./test/check_config.sh

# 2. Instalar (idempotente): squid, rutas, nftables, sysctl, portal
sudo ./scripts/install.sh

# 3. Iniciar el portal
(cd portal && python3 app.py &)

# 4. Estado del nodo
./scripts/status.sh
```

## 7. Evidencias

Ver [`evidencias/README.md`](./evidencias/README.md) — capturas (imágenes, enunciado sección 9) y logs de filtrado, navegación permitida y validación del componente, recogidas el 10-10-2026. Reproducción: `sudo ./test/run_evidence.sh`.

## 8. Estructura de la entrega

```text
E2/
├── README.md                     # Este documento
├── config/
│   ├── squid.conf                # Configuración principal (ACL por VLAN + listas externas)
│   ├── squid.env                 # Variables del componente
│   ├── squid-logrotate           # Rotación de logs
│   ├── squid-transparent.nft     # nftables: redirect 3129 + excepciones + portal
│   └── lists/
│       ├── admins_blacklist      # Dominios bloqueados VLAN ADMIN
│       └── users_blacklist       # Dominios bloqueados VLAN USERS
├── portal/
│   ├── app.py                    # Portal web de consulta de logs (solo VLAN ADMIN)
│   └── requirements.txt          # Flask
├── scripts/
│   ├── install.sh                # Instalador idempotente
│   ├── reload.sh                 # squid -k reconfigure (recarga en caliente)
│   ├── add_domain.sh / remove_domain.sh
│   └── status.sh                 # Estado del nodo
├── test/
│   ├── check_config.sh           # Validación estática
│   └── run_evidence.sh           # Genera evidencias de filtrado
├── docs/
│   ├── Documentacion-Personal-E2.pdf   # Documentación individual (entrega Classroom)
│   └── Documentacion-Personal-E2.html  # Fuente editable de la misma
└── evidencias/
    ├── README.md                 # Índice de evidencias
    ├── capturas/                 # 8 imágenes (capturas) del 10-10-2026
    └── logs/                     # Registros de filtrado, navegación y validación
```