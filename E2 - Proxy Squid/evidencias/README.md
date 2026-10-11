# Evidencias — Estudiante 2 (Proxy Squid)

**Fecha de recolección:** 2026-10-10
**Responsable:** Estudiante 2

Evidencias del funcionamiento del componente E2 conforme al enunciado (sección 5 y 9):
filtrado diferenciado por VLAN, interceptación transparente HTTP, registro de
solicitudes, portal restringido a VLAN ADMIN y capturas (imágenes).

**Alcance:** `test/run_evidence.sh` utiliza el Squid real pero simula IP de clientes VLAN sobre `lo` (loopback). Demuestra filtrado local, no recorrido extremo a extremo E1 → E2 → E5 → E3. `TCP_MISS_ABORTED/000` no acredita navegación exitosa.

---

## 1. Capturas (imágenes)

Enunciado sección 9 — *Evidencias: capturas de Squid, filtrado de dominios, tráfico
permitido/bloqueado, conectividad*. Carpeta [`capturas/`](./capturas/):

| # | Imagen | Qué demuestra |
|---|---|---|
| 01 | `captura-01-filtrado-bloqueados.png` | Filtrado diferenciado: `TCP_DENIED/403` para USERS/ADMIN según su lista; SERVERS/MGMT sin `403` |
| 02 | `captura-02-navegacion-permitida.png` | Navegación permitida con respuestas reales de Internet |
| 03 | `captura-03-estado-componente.png` | `status.sh`: Squid en 3128/3129, redirección y servicios |
| 04 | `captura-04-nftables-redireccion.png` | Tabla `ip squid_transparent`: redirect HTTP a 3129 + excepciones + portal |
| 05 | `captura-05-interfaces-rutas.png` | Interfaces y rutas de E2 (VLANs vía `192.168.84.2`, default vía `192.168.82.1`) |
| 06 | `captura-06-portal-acceso.png` | Portal: `200` desde VLAN ADMIN, `403` desde fuera |
| 07 | `captura-07-portal-web.png` | Portal web renderizado: estadísticas y tabla de logs |
| 08 | `captura-08-whatsapp-equipo-20261010.jpeg` | Foto enviada por el equipo (WhatsApp, 10-10-2026) |

## 2. Matriz demostrada (filtrado diferenciado)

| Origen | Red | Dominio | Resultado en `access.log` | Cumple |
|---|---|---|---|---|
| `192.168.20.10` | VLAN 20 USERS | `www.youtube.com` | `TCP_DENIED/403` | ✅ bloqueado |
| `192.168.20.10` | VLAN 20 USERS | `www.facebook.com` | `TCP_DENIED/403` | ✅ bloqueado |
| `192.168.20.10` | VLAN 20 USERS | `www.tiktok.com` | `TCP_DENIED/403` | ✅ bloqueado |
| `192.168.20.10` | VLAN 20 USERS | `www.netflix.com` | `TCP_DENIED/403` | ✅ bloqueado |
| `192.168.10.50` | VLAN 10 ADMIN | `www.facebook.com` | `TCP_DENIED/403` | ✅ bloqueado (lista ADMIN) |
| `192.168.10.50` | VLAN 10 ADMIN | `www.ilovepdf.com` | `TCP_DENIED/403` | ✅ bloqueado |
| `192.168.30.10` | VLAN 30 SERVERS | `www.youtube.com` | `TCP_MISS_ABORTED/000` (sin 403) | ✅ sin lista, no denegado |
| `192.168.40.10` | VLAN 40 MGMT | `www.facebook.com` | `TCP_MISS_ABORTED/000` (sin 403) | ✅ sin lista, no denegado |

Log: [`logs/filtrado-bloqueos-20261010.log`](./logs/filtrado-bloqueos-20261010.log)

## 3. Navegación permitida con respuesta real de Internet

| Origen | URL | Resultado |
|---|---|---|
| `192.168.10.50` | `http://google.com/` | `TCP_MISS/301` (74.125.139.113) |
| `192.168.10.50` | `http://1.1.1.1/` | `TCP_REFRESH_MODIFIED/301` |
| `192.168.10.50` | `http://www.youtube.com/` | `TCP_MISS/301` (permitido en ADMIN) |
| `192.168.20.10` | `http://deb.debian.org/.../Release` | `TCP_MEM_HIT/200` |
| `192.168.30.10` | `http://deb.debian.org/.../Release` | `TCP_MEM_HIT/200` |

Log: [`logs/navegacion-permitida-ejemplos.log`](./logs/navegacion-permitida-ejemplos.log)

## 4. Validación del componente

- `test/check_config.sh` → **VALIDACION OK**
- Sintaxis de `squid.conf` (`squid -k parse`) → sin errores
- Tabla nft `ip squid_transparent` cargada (`redirect to :3129`, prerouting + output) y **recarga OK** tras reinicio
- Puertos en escucha: `3128` (explícito), `3129` (intercept), `8080` (portal)
- `scripts/status.sh` → todo OK

Log: [`logs/validacion-componente-20261010.log`](./logs/validacion-componente-20261010.log)

## 5. Portal web (solo VLAN ADMIN)

- Origen loopback / simulado `192.168.10.50` → **HTTP 200**
- Origen fuera de VLAN ADMIN → **HTTP 403**
- Refuerzo nftables: `tcp dport 8080 ip saddr != 192.168.10.0/24 drop`

## 6. Reproducción

```bash
sudo ./test/run_evidence.sh
```

Asigna IPs temporales `/32` en `lo` (clientes simulados por VLAN), inyecta HTTP con
`curl --resolve` y el redirect de nftables transporta el tráfico a Squid `3129`.
Imprime los eventos nuevos de `/var/log/squid/access.log`. Las IPs temporales se
eliminan automáticamente al salir (idempotente).