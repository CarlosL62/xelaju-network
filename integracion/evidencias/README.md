# Evidencias de Integración Grupal

Este directorio recopila las evidencias de pruebas conjuntas entre múltiples componentes de la topología XelajuNetwork.

---

## 1. Evidencias Verificadas Actuales

- **Métricas E3 en Zabbix E1:** Verificación de recepción de datos de telemetría de interfaces WAN en el panel de Zabbix Server.
- **Tránsito E4 hacia Internet:** Registros de salida simétrica de paquetes a través de E5 y E3.
- **Detección IDS en Tránsito:** Alertas generadas en Suricata (E5) a partir de tráfico proveniente de E4.

---

## 2. Evidencias Pendientes (Sesión de Laboratorio Conjunta)

1. **Capturas Wireshark Flujo A Completo:** Traza simultánea capturada en R1, Squid, E5 y E3 para una petición HTTP desde un cliente de LAN.
2. **Capturas Wireshark Flujo B Completo:** Traza mostrando el paquete cifrado UDP 51820 ingresando a E4 y el paquete descifrado ingresando a la LAN.
3. **Captura Visual de Acceso ngrok (Flujo C):** Captura de pantalla de navegador accediendo al servicio web DMZ desde Internet a través de la URL de ngrok.
4. **Verificación de Enlace E2 ↔ E5:** Captura de conectividad ARP y ping bidireccional entre `192.168.82.1` y `192.168.82.2` tras revisión física presencial.
