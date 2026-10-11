# Evidencias de Verificación — E5 (Firewall Perimetral e IDS)

**Componente:** E5 — Firewall Perimetral (`nftables`) + IDS (`Suricata 7.0.10`)  
**Responsable:** Estudiante 5 (E5)  
**Curso:** Redes de Computadoras 2 — CUNOC / USAC  
**Sistema:** Debian GNU/Linux 13 (trixie) x86_64 — Kernel `6.12.107+deb13-amd64` (Modo Texto / Consola)  
**Documento maestro de trazabilidad:** [`registro-pruebas.md`](./registro-pruebas.md)

Este directorio documenta el inventario oficial de evidencias técnicas recopiladas para el componente **E5** en la topología XelajuNetwork para el informe individual y entrega académica final.

---

## 1. Estructura de Evidencias Académicas

```text
E5 - Firewall/evidencias/
├── README.md                      # Este índice oficial de evidencias
├── registro-pruebas.md            # Memoria técnica detallada, procedimientos, resultados y conclusiones
├── logs/                          # Registros formateados de ejecución en consola (8 archivos)
│   ├── E5-T00-baseline.log
│   ├── E5-T01-e2-e5.log
│   ├── E5-T02-e3-e5.log
│   ├── E5-T03-e4-e5.log
│   ├── E5-T04-e1-e5.log
│   ├── E5-T05-flujo-a-squid-http.log
│   ├── E5-T12-flujo-c-dmz-ngrok.log
│   ├── E5-T13-zabbix-monitoring.log
│   └── suricata-alert-sample.log  # Muestra histórica de alertas de Suricata
├── pcap/                          # Capturas de tráfico perimetral analizables en Wireshark (8 archivos)
│   ├── E5-T01-e2-e5-connectivity.pcap
│   ├── E5-T02-e3-e5-connectivity.pcap
│   ├── E5-T03-e4-e5-connectivity.pcap
│   ├── E5-T04-e1-e5-routing.pcap
│   ├── E5-T05-flujo-a-squid-http.pcap
│   ├── E5-T05-T13-group-flows.pcap
│   ├── E5-T12-flujo-c-dmz-ngrok.pcap
│   └── E5-T13-zabbix-monitoring.pcap
└── capturas/                      # Directorio reservado para capturas de pantalla PNG de Wireshark GUI
```

---

## 2. Inventario de Evidencias Validadas

| Archivo | Tipo | Tamaño | Respaldo y Demostración Objetiva |
|---|:---:|:---:|---|
| [`logs/E5-T00-baseline.log`](./logs/E5-T00-baseline.log) | Log | 4.0 KB | Estado operativo inicial de interfaces `/30`, forwarding kernel `ip_forward=1`, tablas de rutas y reglas activas. |
| [`logs/E5-T01-e2-e5.log`](./logs/E5-T01-e2-e5.log)<br>[`pcap/E5-T01-e2-e5-connectivity.pcap`](./pcap/E5-T01-e2-e5-connectivity.pcap) | Log<br>PCAP | 3.5 KB<br>16.1 KB | Enlace punto a punto E2–E5 (`192.168.82.0/30`), resolución ARP mutua, 8 paquetes ICMP (0% loss) y alertas de Suricata `SID 1000001` en `enxc0eac367f731`. |
| [`logs/E5-T02-e3-e5.log`](./logs/E5-T02-e3-e5.log)<br>[`pcap/E5-T02-e3-e5-connectivity.pcap`](./pcap/E5-T02-e3-e5-connectivity.pcap) | Log<br>PCAP | 3.1 KB<br>10.6 KB | Enlace perimetral E3–E5 (`192.168.81.0/30`), sondeo ICMP 4/4 bidireccional y alertas IDS en `eno2`. |
| [`logs/E5-T03-e4-e5.log`](./logs/E5-T03-e4-e5.log)<br>[`pcap/E5-T03-e4-e5-connectivity.pcap`](./pcap/E5-T03-e4-e5-connectivity.pcap) | Log<br>PCAP | 3.2 KB<br>1.5 KB | Enlace DMZ/VPN E4–E5 (`192.168.83.0/30`), tráfico ICMP 4/4 e inspección pasiva en `enxf8e43ba69459`. |
| [`logs/E5-T04-e1-e5.log`](./logs/E5-T04-e1-e5.log)<br>[`pcap/E5-T04-e1-e5-routing.pcap`](./pcap/E5-T04-e1-e5-routing.pcap) | Log<br>PCAP | 2.9 KB<br>26.5 KB | Enrutamiento multihop LAN E1 hacia E5 a través de E2 con decremento de TTL=63 y paquetes ICMP *Time exceeded* de retorno. |
| [`logs/E5-T05-flujo-a-squid-http.log`](./logs/E5-T05-flujo-a-squid-http.log)<br>[`pcap/E5-T05-flujo-a-squid-http.pcap`](./pcap/E5-T05-flujo-a-squid-http.pcap) | Log<br>PCAP | 2.5 KB<br>2.4 KB | Flujo A: egreso web HTTP (puerto 80) hacia Internet (`1.1.1.1:80`) retornando `200 OK`. Observación de 20 paquetes SYN en TCP 443 sin respuesta. |
| [`pcap/E5-T05-T13-group-flows.pcap`](./pcap/E5-T05-T13-group-flows.pcap) | PCAP | 1.82 MB | Concurrencia multi-flujo: 2,634 paquetes capturados demostrando tráfico simultáneo web, telemetría Zabbix y túnel ngrok. |
| [`logs/E5-T12-flujo-c-dmz-ngrok.log`](./logs/E5-T12-flujo-c-dmz-ngrok.log)<br>[`pcap/E5-T12-flujo-c-dmz-ngrok.pcap`](./pcap/E5-T12-flujo-c-dmz-ngrok.pcap) | Log<br>PCAP | 2.6 KB<br>56.3 KB | Flujo C: sesión continua `TLSv1.2` bidireccional (448 paquetes) entre E4 y ngrok (`3.134.73.173:443`) para publicar WEB01. |
| [`logs/E5-T13-zabbix-monitoring.log`](./logs/E5-T13-zabbix-monitoring.log)<br>[`pcap/E5-T13-zabbix-monitoring.pcap`](./pcap/E5-T13-zabbix-monitoring.pcap) | Log<br>PCAP | 2.5 KB<br>49.8 KB | Contrato `SEC-E1-MONITORING`: handshake TCP completo y active checks del agente Zabbix de E3 hacia `192.168.30.10:10051`. |

---

## 3. Verificación de Integridad Criptográfica (SHA-256)

Los 16 archivos coinciden bit a bit con los conservados en el repositorio de coordinación:

- `logs/E5-T00-baseline.log`: `85a179614d90f6b4d58358298aaeac3f4c91db15c35e8886b5605e46470b1aa8`
- `logs/E5-T01-e2-e5.log`: `92688ee2462503f1abb795950667e5ae7fb4add7fe3cc53b985826563e349458`
- `logs/E5-T02-e3-e5.log`: `74e1d58d896482caec8777ae6bbd8cc99d1ac26759ca479d9af71221a828978f`
- `logs/E5-T03-e4-e5.log`: `ee0f3586cb79b0189d80a830756a2e58ade3373a10a6c32d10938aec7e94855a`
- `logs/E5-T04-e1-e5.log`: `5b00c1b7ef3c17ac007847cbb3adf4f10b518da582fe989d37e187590a2a0adb`
- `logs/E5-T05-flujo-a-squid-http.log`: `b903bb817b68f9051226c62eaafd653f5a058ccbf8abfde399335f213993fdd0`
- `logs/E5-T12-flujo-c-dmz-ngrok.log`: `3ec0423a2796b1c285ec4bc4011fdbd241c556b4e6c734fc6deaa263b684e503`
- `logs/E5-T13-zabbix-monitoring.log`: `ea3c17af1f97eae776d5172cc63df1beebf176aefc9f4b4dcce97afabf5372ba`
- `pcap/E5-T01-e2-e5-connectivity.pcap`: `2ca4d3b1e65b9c0ab510aca5ccf270f36595b534e6c0a4fee8e5c527730f28d6`
- `pcap/E5-T02-e3-e5-connectivity.pcap`: `46dd13e523058875a8f4b0093c115fb16970e1120202fda2b5263013a42404e7`
- `pcap/E5-T03-e4-e5-connectivity.pcap`: `bbb47f4216111c8062d8bf1759cca738ad740f5cee0b7ba639603e54b7076940`
- `pcap/E5-T04-e1-e5-routing.pcap`: `4a4bfbc1b9655f6713aa49e221089aa2b2423afc69241d8cec9bd255c7d5637b`
- `pcap/E5-T05-flujo-a-squid-http.pcap`: `806635d7f96313335647766640de00271ce87da20b2351935fe84612f6f74833`
- `pcap/E5-T05-T13-group-flows.pcap`: `ab3dce315a6ec44b6333aafe208a96f39373e68ee86ecc0344944823e49df504`
- `pcap/E5-T12-flujo-c-dmz-ngrok.pcap`: `7db7a04eec0e19dde382f01e4b4c98f04d2d475d14a64adcf7ba94623d83365d`
- `pcap/E5-T13-zabbix-monitoring.pcap`: `7fd2692a15159db77ddba68f406d391966d410d102a3700b89e08a698b9ce548`
