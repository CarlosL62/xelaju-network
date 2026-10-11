# Estudiante 4 — WireGuard VPN y Zona Desmilitarizada (DMZ)

**Responsable:** Estudiante 4<br>
**Curso:** Redes de Computadoras 2 — CUNOC / USAC<br>
**Sistema:** Debian GNU/Linux (Modo Consola / Texto)<br>
**Rol en la infraestructura:** Servidor de acceso remoto seguro mediante WireGuard VPN con subredes diferenciadas, alojamiento de servicios DMZ (WEB01) y publicación externa mediante túnel seguro ngrok.

---

## 1. Descripción y Responsabilidad del Componente

El componente **E4** concentra la terminación de accesos remotos y los servicios públicos perimetrales de XelajuNetwork. Sus responsabilidades son:
- Implementación de un servidor VPN WireGuard en Debian con asignación de rangos IP diferenciados para usuarios administrativos (`VPN-ADMIN: 10.200.10.0/24`) y usuarios comunes (`VPN-USERS: 10.200.20.0/24`).
- Conexión física exclusiva hacia el firewall perimetral E5 a través del enlace `192.168.83.0/30`, asegurando que todo el tráfico pase por el firewall perimetral antes y después de su procesamiento (modelo de doble pasada).
- Alojamiento y mantenimiento de la zona desmilitarizada (DMZ) en la subred `172.16.10.0/24`, donde opera el servidor web perimetral WEB01 (`172.16.10.10`).
- Publicación hacia Internet de al menos un servicio DMZ a través de un túnel ngrok originado hacia el exterior desde el entorno interno, sin requerir una dirección IPv4 pública directa en el servidor.

---

## 2. Requisitos del Enunciado Oficial

- **Servidor WireGuard:** Servicio VPN activo en Debian en el puerto UDP 51820.
- **Diferenciación de Clientes VPN:** Asignación estricta de subredes para permitir que E5 aplique reglas de acceso diferenciadas hacia la LAN corporativa.
- **Servicios DMZ:** Configuración de servidor web perimetral en la subred DMZ accesible desde clientes autorizados.
- **Túnel ngrok:** Publicación segura del servicio web con URL pública accesible para usuarios externos.

---

## 3. Configuraciones

*(Sección reservada para la incorporación de configuraciones por el Estudiante 4)*

- Configuración de la interfaz `wg0` en `/etc/wireguard/wg0.conf`.
- Configuración de interfaz hacia E5 (`192.168.83.2/30`) e interfaz DMZ (`172.16.10.1/24`).
- Configuración del servidor web en DMZ (nginx, Apache o contenedor).
- Configuración del agente y servicio del túnel ngrok.

---

## 4. Scripts

*(Sección reservada para los scripts operativos del Estudiante 4)*

- Scripts de inicialización y parada de la VPN WireGuard.
- Herramienta de alta y gestión de claves y clientes remotos (*peers*).
- Scripts de inicio y verificación del túnel ngrok y servicio web.

---

## 5. Funcionamiento

- **Flujo B (Acceso Remoto VPN):** Clientes remotos se conectan por WireGuard cruzando E5 hacia E4. E4 descifra los paquetes y los reenvía por su ruta por defecto de vuelta a E5 (`192.168.83.1`), donde el firewall aplica las políticas de acceso hacia LAN.
- **Flujo C (Publicación DMZ):** El servicio web WEB01 corre localmente en la DMZ. El agente ngrok establece una conexión saliente TLS hacia los servidores de ngrok, permitiendo el ingreso de usuarios externos sin abrir puertos directos en el router.

---

## 6. Evidencias y Pruebas

*(Sección reservada para el reporte de pruebas del Estudiante 4)*

- Comprobación de handshake y transferencia de datos en WireGuard.
- Comprobación de acceso de cliente VPN-ADMIN a la LAN y restricción de VPN-USERS.
- Acceso exitoso a la URL pública de ngrok desde navegadores externos.

---

## 7. Observaciones y Pendientes

- La entrega de configuraciones definitivas y capturas de pantalla corresponde al Estudiante 4.
- Pendiente la prueba integral conjunta simultánea con los 5 nodos concurrentes en el laboratorio.
