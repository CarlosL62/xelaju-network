# Estudiante 1 — Segmentación LAN, DHCP y Monitoreo Zabbix

**Responsable:** Estudiante 1<br>
**Curso:** Redes de Computadoras 2 — CUNOC / USAC<br>
**Sistema:** Debian GNU/Linux (Modo Consola / Texto)<br>
**Rol en la infraestructura:** Enrutamiento inter-VLAN interno, control de acceso local, servidor DHCP restringido para usuarios y plataforma centralizada de monitoreo de red (Zabbix).

---

## 1. Descripción y Responsabilidad del Componente

El componente **E1** gestiona la infraestructura de red local (LAN) corporativa de XelajuNetwork. Sus responsabilidades asignadas según el diseño de arquitectura son:
- Implementación de la segmentación en red local mediante un esquema de al menos 4 VLANs lógicas bajo el estándar IEEE 802.1Q.
- Enrutamiento inter-VLAN y aplicación de listas de control de acceso (ACLs) locales para gobernar el tráfico interno entre departamentos.
- Provisión de servicio DHCP restringido exclusivamente al segmento de usuarios (VLAN 20), basado en reservas estáticas MAC-IP mediante servicio nativo tradicional de Debian (Kea DHCP estrictamente prohibido).
- Alojamiento y configuración del servidor central de monitoreo Zabbix (`192.168.30.10`) para recolección de métricas de todos los nodos de la infraestructura.

---

## 2. Requisitos del Enunciado Oficial

- **Segmentación VLAN:** Definición de VLAN 10 (Administración), VLAN 20 (Usuarios), VLAN 30 (Servidores) y VLAN 40 (Gestión).
- **Políticas de Acceso Internas:** Aislamiento de tráfico entre usuarios y administración; acceso controlado de usuarios hacia la intranet web en VLAN 30.
- **Servidor DHCP:** Servicio restringido a la VLAN 20. Cualquier equipo con dirección MAC no registrada en el inventario no debe recibir concesión de IP ni acceso a la red.
- **Monitoreo Zabbix:** Servidor Zabbix operativo en la VLAN de servidores, accesible únicamente desde la VLAN de administración y configurado para recibir métricas activas de los nodos E2, E3, E4 y E5.

---

## 3. Configuraciones

*(Sección reservada para la incorporación de configuraciones por el Estudiante 1)*

- Configuración de subinterfaces VLAN en `/etc/network/interfaces`.
- Configuración del servicio DHCP tradicional en `/etc/dhcp/dhcpd.conf` y archivo de usuarios autorizados.
- Reglas de filtrado y control de acceso inter-VLAN (`nftables`).
- Configuración del servidor Zabbix y su interfaz web.

---

## 4. Scripts

*(Sección reservada para los scripts operativos del Estudiante 1)*

- Scripts de inicialización y validación del enrutador R1-LAN y switches virtuales/físicos.
- Herramientas de consulta y administración de concesiones DHCP.
- Scripts de aprovisionamiento de agentes o plantillas de Zabbix.

---

## 5. Funcionamiento

- **Tráfico Inter-VLAN:** El tráfico entre segmentos locales es procesado y evaluado por R1-LAN aplicando la política por omisión de descarte (`policy drop`).
- **Tránsito Hacia el Perímetro:** El tráfico saliente de la LAN hacia Internet o la DMZ se encamina a través del enlace de tránsito `192.168.84.0/30` hacia el proxy E2 (`192.168.84.1`).

---

## 6. Evidencias y Pruebas

*(Sección reservada para el reporte de pruebas del Estudiante 1)*

- Capturas de asignación correcta de DHCP para MACs autorizadas y rechazo de intrusos.
- Pruebas de comunicación permitida (VLAN 10 -> todas; VLAN 20 -> Intranet).
- Pruebas de comunicación bloqueada (VLAN 20 -> VLAN 10).
- Panel de control de Zabbix con recolección de métricas activa.

---

## 7. Observaciones y Pendientes

- La entrega de configuraciones definitivas y capturas de pantalla corresponde al Estudiante 1.
- Pendiente la prueba integral conjunta simultánea con los 5 nodos concurrentes en el laboratorio.
