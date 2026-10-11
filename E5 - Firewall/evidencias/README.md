# Evidencias de Verificación — E5 (Firewall Perimetral e IDS)

**Componente:** E5 — Firewall Perimetral (`nftables`) + IDS (`Suricata 7.0.10`)  
**Responsable:** Estudiante 5 (E5)  
**Curso:** Redes de Computadoras 2 — CUNOC / USAC  
**Entorno:** Debian GNU/Linux 13 (trixie) x86_64 — Kernel `6.12.107+deb13-amd64` (Modo Texto)  

Índice de ubicación de las evidencias técnicas del componente E5. Las explicaciones, análisis y conclusiones completas se presentan en los documentos PDF de entrega final.

---

## 1. Estructura de Evidencias

```text
E5 - Firewall/evidencias/
├── README.md                      # Este índice de archivos
├── logs/                          # Registros formateados de consola (6 archivos)
│   ├── E5-T00-baseline.log
│   ├── E5-T01-e2-e5.log
│   ├── E5-T02-e3-e5.log
│   ├── E5-T03-e4-e5.log
│   ├── E5-T04-e1-e5.log
│   └── E5-T13-zabbix-monitoring.log
├── pcap/                          # Capturas de tráfico perimetral para Wireshark (7 archivos)
│   ├── E5-T01-e2-e5-connectivity.pcap
│   ├── E5-T02-e3-e5-connectivity.pcap
│   ├── E5-T03-e4-e5-connectivity.pcap
│   ├── E5-T04-e1-e5-routing.pcap
│   ├── E5-T05-T13-group-flows.pcap
│   ├── E5-T12-flujo-c-dmz-ngrok.pcap
│   └── E5-T13-zabbix-monitoring.pcap
└── capturas/                      # Directorio para capturas visuales de Wireshark GUI
```

---

## 2. Inventario de Evidencias Técnicas

| Archivo | Tipo | Tamaño | Descripción Técnica |
|---|:---:|:---:|---|
| [`logs/E5-T00-baseline.log`](./logs/E5-T00-baseline.log) | Log | 4.0 KB | Estado operativo de interfaces `/30`, reenvío en kernel (`net.ipv4.ip_forward = 1`), rutas y servicios activos. |
| [`logs/E5-T01-e2-e5.log`](./logs/E5-T01-e2-e5.log)<br>[`pcap/E5-T01-e2-e5-connectivity.pcap`](./pcap/E5-T01-e2-e5-connectivity.pcap) | Log<br>PCAP | 3.5 KB<br>16.1 KB | Enlace E2–E5 (`192.168.82.0/30`), resolución ARP, ICMP bidireccional y alertas Suricata `SID 1000001` en `enxc0eac367f731`. |
| [`logs/E5-T02-e3-e5.log`](./logs/E5-T02-e3-e5.log)<br>[`pcap/E5-T02-e3-e5-connectivity.pcap`](./pcap/E5-T02-e3-e5-connectivity.pcap) | Log<br>PCAP | 3.1 KB<br>10.6 KB | Enlace E3–E5 (`192.168.81.0/30`), sondeo ICMP bidireccional y alertas IDS en `eno2`. |
| [`logs/E5-T03-e4-e5.log`](./logs/E5-T03-e4-e5.log)<br>[`pcap/E5-T03-e4-e5-connectivity.pcap`](./pcap/E5-T03-e4-e5-connectivity.pcap) | Log<br>PCAP | 3.2 KB<br>1.5 KB | Enlace E4–E5 (`192.168.83.0/30`), resolución ARP, paquetes ICMP y detección IDS en `enxf8e43ba69459`. |
| [`logs/E5-T04-e1-e5.log`](./logs/E5-T04-e1-e5.log)<br>[`pcap/E5-T04-e1-e5-routing.pcap`](./pcap/E5-T04-e1-e5-routing.pcap) | Log<br>PCAP | 2.9 KB<br>26.5 KB | Enrutamiento multihop LAN (E1) hacia E5 a través de E2 con decremento de TTL=63 e ICMP Time exceeded. |
| [`pcap/E5-T05-T13-group-flows.pcap`](./pcap/E5-T05-T13-group-flows.pcap) | PCAP | 1.82 MB | Captura de concurrencia perimetral: tráfico simultáneo de telemetría Zabbix y sesiones TLS. |
| [`pcap/E5-T12-flujo-c-dmz-ngrok.pcap`](./pcap/E5-T12-flujo-c-dmz-ngrok.pcap) | PCAP | 56.3 KB | Flujo C: transporte `TLSv1.2` (448 paquetes) entre E4 (`192.168.83.2`) y ngrok (`3.134.73.173:443`) a través de E5. |
| [`logs/E5-T13-zabbix-monitoring.log`](./logs/E5-T13-zabbix-monitoring.log)<br>[`pcap/E5-T13-zabbix-monitoring.pcap`](./pcap/E5-T13-zabbix-monitoring.pcap) | Log<br>PCAP | 2.5 KB<br>49.8 KB | Contrato `SEC-E1-MONITORING`: handshake TCP y active checks del agente Zabbix de E3 hacia `192.168.30.10:10051`. |

---

## 3. Integridad Criptográfica (SHA-256)

- `logs/E5-T00-baseline.log`: `85a179614d90f6b4d58358298aaeac3f4c91db15c35e8886b5605e46470b1aa8`
- `logs/E5-T01-e2-e5.log`: `92688ee2462503f1abb795950667e5ae7fb4add7fe3cc53b985826563e349458`
- `logs/E5-T02-e3-e5.log`: `74e1d58d896482caec8777ae6bbd8cc99d1ac26759ca479d9af71221a828978f`
- `logs/E5-T03-e4-e5.log`: `ee0f3586cb79b0189d80a830756a2e58ade3373a10a6c32d10938aec7e94855a`
- `logs/E5-T04-e1-e5.log`: `5b00c1b7ef3c17ac007847cbb3adf4f10b518da582fe989d37e187590a2a0adb`
- `logs/E5-T13-zabbix-monitoring.log`: `ea3c17af1f97eae776d5172cc63df1beebf176aefc9f4b4dcce97afabf5372ba`
- `pcap/E5-T01-e2-e5-connectivity.pcap`: `2ca4d3b1e65b9c0ab510aca5ccf270f36595b534e6c0a4fee8e5c527730f28d6`
- `pcap/E5-T02-e3-e5-connectivity.pcap`: `46dd13e523058875a8f4b0093c115fb16970e1120202fda2b5263013a42404e7`
- `pcap/E5-T03-e4-e5-connectivity.pcap`: `bbb47f4216111c8062d8bf1759cca738ad740f5cee0b7ba639603e54b7076940`
- `pcap/E5-T04-e1-e5-routing.pcap`: `4a4bfbc1b9655f6713aa49e221089aa2b2423afc69241d8cec9bd255c7d5637b`
- `pcap/E5-T05-T13-group-flows.pcap`: `ab3dce315a6ec44b6333aafe208a96f39373e68ee86ecc0344944823e49df504`
- `pcap/E5-T12-flujo-c-dmz-ngrok.pcap`: `7db7a04eec0e19dde382f01e4b4c98f04d2d475d14a64adcf7ba94623d83365d`
- `pcap/E5-T13-zabbix-monitoring.pcap`: `7fd2692a15159db77ddba68f406d391966d410d102a3700b89e08a698b9ce548`
