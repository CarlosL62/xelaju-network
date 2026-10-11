# Evidencias de Integración Grupal

Este directorio indexa evidencias entre componentes de XelajuNetwork. Las capturas y logs están en carpetas de nodos. No acredita una prueba simultánea completa de cinco nodos.

---

## 1. Evidencias Verificadas Actuales

- **Métricas E3 en Zabbix E1:** Verificación de recepción de datos de telemetría de interfaces WAN en el panel de Zabbix Server.
- **Tránsito E4 hacia Internet:** Registros de salida simétrica de paquetes a través de E5 y E3.
- **Detección IDS en Tránsito:** Alertas generadas en Suricata (E5) a partir de tráfico proveniente de E4.
- **E2 ↔ E5 (11/10/2026):** ARP, ICMP bidireccional y alerta SID 1000001 documentados en [`E5-T01`](../../E5%20-%20Firewall/evidencias/logs/E5-T01-e2-e5.log) y [su PCAP](../../E5%20-%20Firewall/evidencias/pcap/E5-T01-e2-e5-connectivity.pcap). Esto verifica el enlace en esa sesión.

---

## 2. Evidencias Pendientes (Sesión de Laboratorio Conjunta)

1. **Capturas Wireshark Flujo A Completo:** Traza simultánea capturada en R1, Squid, E5 y E3 para una petición HTTP desde un cliente de LAN.
2. **Capturas Wireshark Flujo B Completo:** Traza mostrando el paquete cifrado UDP 51820 ingresando a E4 y el paquete descifrado ingresando a la LAN.
3. **Captura Visual de Acceso ngrok (Flujo C):** Captura de pantalla de navegador accediendo al servicio web DMZ desde Internet a través de la URL de ngrok.
