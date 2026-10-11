# Evidencias de Verificación — E5 (Firewall Perimetral e IDS)

Este directorio documenta el estado y el inventario de las evidencias técnicas recopiladas para el componente **E5** en la topología XelajuNetwork.

---

## 1. Inventario de Evidencias Técnicas Disponibles

### A. Registros de Detección de Suricata IDS
- **Ubicación en host físico:** `/var/log/suricata/fast.log` y `/var/log/suricata/eve.json`.
- **Muestra versionada:** [`logs/suricata-alert-sample.log`](./logs/suricata-alert-sample.log).
- **Descripción:** Evidencia de activación del motor Suricata 7.0.10 en modo `af-packet` sobre interfaces perimetrales, detectando tráfico ICMP generado desde el enlace de E4 mediante la regla local `SID 1000001` (`ICMP Echo Request detectado`).

### B. Capturas de Tráfico Perimetral (PCAP)
- **Ubicación en host físico:** `/var/log/xelaju-e5/captures/capture_all_20261010_204538.pcap`.
- **Herramienta de recolección:** Script [`../scripts/e5-capture`](../scripts/e5-capture) sobre interfaces `eno2`, `enxc0eac367f731` y `enxf8e43ba69459`.
- **Descripción:** Tráfico perimetral capturado durante las sesiones de integración bilateral (tránsito E4 hacia Internet y tráfico con estado).

---

## 2. Evidencias Pendientes para la Entrega Académica Final

De acuerdo con los requisitos del enunciado (Sección 9):

1. **Capturas Visuales de Interfaz Gráfica (Wireshark GUI):**
   - Apertura del archivo `capture_all_20261010_204538.pcap` en Wireshark gráfico para exportar capturas de pantalla de los paquetes de tránsito perimetral y el handshake de túneles.
   - Capturas visuales de terminal mostrando la ejecución en tiempo real de `e5-ids alerts` (`tail -f /var/log/suricata/fast.log`).
2. **Pruebas de Integración Grupal Simultánea:**
   - Capturas del filtrado perimetral con los 5 nodos concurrentes activos en el laboratorio (Flujos A, B y C).
   - Resolución y validación visual del enlace E2 ↔ E5 tras la comprobación física de cableado.
