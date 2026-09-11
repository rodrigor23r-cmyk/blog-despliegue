#!/usr/bin/env bash
#
# Abre un túnel SSH hasta el MySQL del VPS para poder usar DBeaver.
# Busca la IP del contenedor cada vez, porque cambia al recrearlo.
#
#   bash tunel-mysql.sh          -> localhost:3307
#
# Luego, en DBeaver: host 127.0.0.1, puerto 3307, base 'gastos',
# usuario 'gastos_user'. SIN activar el túnel SSH de DBeaver: ya está hecho aquí.
set -euo pipefail

VPS=${VPS:-deploy@77.37.122.44}
PUERTO_LOCAL=${PUERTO_LOCAL:-3307}

echo "Buscando la IP actual del contenedor de MySQL..."
IP=$(ssh "$VPS" 'cd /opt/blog && docker inspect -f "{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}" $(docker compose ps -q db)' | tr -d '[:space:]')

if [ -z "$IP" ]; then
    echo "ERROR: no he obtenido ninguna IP. ¿Está levantado el contenedor 'db'?" >&2
    exit 1
fi

echo "Contenedor en $IP"
echo "Túnel abierto: localhost:$PUERTO_LOCAL  ->  $IP:3306"
echo "Déjalo corriendo. Ctrl+C para cerrarlo."
exec ssh -N -L "$PUERTO_LOCAL:$IP:3306" "$VPS"
