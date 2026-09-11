#!/usr/bin/env bash
#
# Despliega gastos-api en el VPS. Idempotente: relanzarlo actualiza y reconstruye.
#
#   cd /opt/blog && bash desplegar-gastos.sh
#
set -euo pipefail
cd "$(dirname "$0")"

REPO=${REPO:-https://github.com/rodrigor23r-cmyk/gastos_backend.git}
DIRECTORIO=gastos-backend          # OJO: guion medio. El compose espera ./gastos-backend
DOMINIO_API=api.gastos.taller-barataria.io

[ -f docker-compose.yml ] && [ -f .env ] || {
    echo "ERROR: aquí no están docker-compose.yml y .env." >&2; exit 1; }

# ---------- 1. Comprobaciones previas ----------
echo "== Comprobando el .env =="
for v in GASTOS_DB_USER GASTOS_DB_PASSWORD GASTOS_JWT_SECRET DOMINIO; do
    if ! grep -q "^${v}=..*" .env; then
        echo "ERROR: falta $v en .env, o está vacío. Ejecuta antes preparar-gastos.sh" >&2
        exit 1
    fi
done
echo "  las cuatro variables están."

# ---------- 2. Traer el código ----------
if [ -d "$DIRECTORIO/.git" ]; then
    echo "== Actualizando $DIRECTORIO =="
    git -C "$DIRECTORIO" pull --ff-only
else
    echo "== Clonando $DIRECTORIO =="
    # El repositorio se llama gastos_backend pero el directorio DEBE ser gastos-backend.
    if ! git clone "$REPO" "$DIRECTORIO"; then
        echo >&2
        echo "ERROR al clonar. Si el repositorio es privado, el VPS necesita credenciales." >&2
        echo "Comprueba cómo se autentica con: git -C blog remote -v  y  git -C blog pull" >&2
        exit 1
    fi
fi
echo "  en el commit: $(git -C "$DIRECTORIO" log --oneline -1)"

# ---------- 3. Construir y levantar ----------
echo "== Construyendo y levantando gastos-api (la primera vez tarda varios minutos) =="
docker compose up -d --build gastos-api

# ---------- 4. Esperar a que el healthcheck lo dé por sano ----------
echo -n "== Esperando a que esté sano "
ID=$(docker compose ps -q gastos-api)
for i in $(seq 1 60); do
    ESTADO=$(docker inspect -f '{{.State.Health.Status}}' "$ID" 2>/dev/null || echo desconocido)
    [ "$ESTADO" = healthy ] && { echo " -> $ESTADO"; break; }
    [ "$ESTADO" = unhealthy ] && { echo " -> $ESTADO"; break; }
    echo -n "."; sleep 5
done
if [ "${ESTADO:-}" != healthy ]; then
    echo
    echo "NO está sano. Últimas líneas del log:" >&2
    docker compose logs --tail 30 gastos-api >&2
    exit 1
fi

# ---------- 5. Recargar Caddy para que sirva el sitio nuevo ----------
# Recargar y no reiniciar: el blog no se entera.
echo "== Recargando Caddy =="
docker compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile

# ---------- 6. Comprobar de extremo a extremo ----------
echo
echo "===== COMPROBACIÓN ====="
echo "-- Flyway (debe haber aplicado 3 migraciones) --"
docker compose logs gastos-api 2>/dev/null | grep -i "Successfully applied\|Successfully validated" | tail -2 || echo "  (sin líneas de Flyway)"

echo "-- Tablas creadas --"
docker compose exec -T db sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysql -uroot -N -e "
SELECT COUNT(*) FROM information_schema.tables WHERE table_schema=\"gastos\";"' | xargs -I{} echo "  {} tablas (deben ser 6: las 5 del modelo + flyway_schema_history)"

echo "-- HTTPS a través de Caddy (puede tardar en el primer certificado) --"
for i in $(seq 1 12); do
    CODIGO=$(curl -sS -o /dev/null -w '%{http_code}' "https://$DOMINIO_API/actuator/health" 2>/dev/null || echo 000)
    [ "$CODIGO" = 200 ] && break
    echo -n "."; sleep 5
done
echo "  https://$DOMINIO_API/actuator/health -> $CODIGO   (debe ser 200)"

echo "-- Swagger debe estar APAGADO en prod --"
curl -sS -o /dev/null -w "  /v3/api-docs -> %{http_code}   (debe ser 404)\n" "https://$DOMINIO_API/v3/api-docs" || true

echo "-- Sin token, la API debe rechazar --"
curl -sS -o /dev/null -w "  /api/saldo -> %{http_code}   (debe ser 401)\n" "https://$DOMINIO_API/api/saldo" || true

echo
echo "Listo. La base 'gastos' está vacía de datos: el histórico se traslada aparte (§12.7)."
