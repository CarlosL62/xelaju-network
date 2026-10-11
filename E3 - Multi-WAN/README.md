# Estudiante 3 — Enrutamiento Multi-WAN y Tolerancia a Fallos

**Responsable:** Estudiante 3<br>
**Curso:** Redes de Computadoras 2 — CUNOC / USAC<br>
**Sistema:** Debian GNU/Linux (Modo Consola / Texto)<br>
**Rol en la infraestructura:** Conectividad externa hacia múltiples proveedores de Internet (ISPs), distribución de tráfico saliente por políticas, conmutación por error (*failover*) y exportación de métricas a Zabbix.

---

## 1. Descripción y Responsabilidad del Componente

El componente **E3** opera como el router de borde externo para XelajuNetwork. Sus responsabilidades comprenden:
- Conexión física y lógica hacia dos enlaces independientes de Internet (ISP1 e ISP2).
- Enrutamiento basado en políticas (*Policy-Based Routing / PBR*) para distribuir el tráfico corporativo entre ambos proveedores según el origen o tipo de servicio.
- Detección automática de fallos en los enlaces WAN y conmutación transparente (*failover* dinámico) hacia el enlace sobreviviente.
- Traducción de direcciones de red (Source NAT / Masquerade) centralizada en la salida hacia los ISPs.
- Provisión de métricas de tráfico entrante y saliente de ambos ISPs hacia el servidor Zabbix en E1.

---

## 2. Requisitos del Enunciado Oficial

- **Doble Enlace WAN:** Configuración de dos salidas a Internet activas de forma concurrente.
- **Políticas de Distribución:** Enrutamiento diferenciado según el tipo de tráfico de origen (usuarios, administración, DMZ, VPN).
- **Mecanismo de Failover:** Detección de pérdida de conectividad en ISP principal y conmutación automática de rutas hacia el enlace secundario, con restauración tras recuperación.
- **Telemetría para Monitoreo:** Envío periódico o continuo de estadísticas de ancho de banda y uso de ambos enlaces al servidor Zabbix.

---

## 3. Configuraciones

*(Sección reservada para la incorporación de configuraciones por el Estudiante 3)*

- Configuración de interfaces WAN y LAN perimetral (`192.168.81.1/30`).
- Tablas de enrutamiento múltiples en Linux (`/etc/iproute2/rt_tables`) y reglas `ip rule`.
- Reglas de NAT / Masquerade en `nftables`.
- Configuración de scripts o demonios de monitoreo de enlace para failover.

---

## 4. Scripts

*(Sección reservada para los scripts operativos del Estudiante 3)*

- Scripts de inicialización de tablas de enrutamiento y balanceo.
- Scripts de comprobación de salud de los enlaces (healthcheck / ping probes).
- Script de exportación de métricas de red hacia Zabbix (`setup_zabbix.sh`).

---

## 5. Funcionamiento

- **Tránsito Perimetral:** E3 recibe tráfico desde el firewall E5 a través del enlace `192.168.81.0/30`. Aplica las reglas PBR para seleccionar el ISP de salida y ejecuta NAT sobre el paquete saliente.
- **Retorno Simétrico:** Las rutas internas hacia las subredes LAN, VPN y DMZ apuntan hacia E5 (`192.168.81.2`) para asegurar que el tráfico entrante de respuesta sea entregado correctamente al perímetro.

---

## 6. Evidencias y Pruebas

*(Sección reservada para el reporte de pruebas del Estudiante 3)*

- Pruebas de salida a Internet a través de ISP1 e ISP2 según política.
- Simulación de corte de enlace en ISP1 y comprobación de failover hacia ISP2.
- Capturas de gráficas y métricas de tráfico registradas en Zabbix.

---

## 7. Observaciones y Pendientes

- La entrega de configuraciones definitivas y capturas de pantalla corresponde al Estudiante 3.
- Pendiente la prueba integral conjunta simultánea con los 5 nodos concurrentes en el laboratorio.
