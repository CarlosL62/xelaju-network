#!/bin/bash
# Recarga la configuracion de Squid tras modificar las listas
squid -k reconfigure && echo "[OK] Squid reconfigurado. Nuevas listas aplicadas."
