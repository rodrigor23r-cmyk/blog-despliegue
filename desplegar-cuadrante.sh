#!/usr/bin/env bash
#
# Despliega cuadrante en el VPS: la API, la web o las dos. Copia adaptada de
# desplegar-gastos.sh. Idempotente: relanzarlo actualiza y reconstruye.
#
#   cd /opt/blog && bash desplegar-cuadrante.sh          # las dos
#   cd /opt/blog && bash desplegar-cuadrante.sh api      # solo la API
#   cd /opt/blog && bash desplegar-cuadrante.sh web      # solo la web
#
set -euo pipefail
cd "$(dirname "$0")"

QUE=${1:-todo}
case "$QUE" in
    api|web|todo) ;;
    *) echo "Uso: bash desplegar-cuadrante.sh [api|web|todo]" >&2; exit 1 ;;
esac

# Los dos repositorios son PRIVADOS (§5 de cuadrante): se clonan por SSH con una clave de
# despliegue de solo lectura cada uno. GitHub no deja usar la misma clave en dos repositorios,
# así que cada uno tiene su alias en ~/.ssh/config (github-cuadrante-backend y -frontend),
# que dice qué clave usar. Cómo crearlas: DESPLIEGUE.md, «Caso E».
REPO_API=${REPO_API:-git@github-cuadrante-backend:rodrigor23r-cmyk/cuadrante_backend.git}
REPO_WEB=${REPO_WEB:-git@github-cuadrante-frontend:rodrigor23r-cmyk/cuadrante_frontend.git}
DOMINIO_API=api.cuadrante.taller-barataria.io
DOMINIO_WEB=cuadrante.taller-barataria.io

[ -f docker-compose.yml ] && [ -f .env ] || {
    echo "ERROR: aquí no están docker-compose.yml y .env." >&2; exit 1; }

# ---------- 1. Comprobaciones previas ----------
if [ "$QUE" != web ]; then
    echo "== Comprobando el .env =="
    for v in DOMINIO CUADRANTE_DB_USER CUADRANTE_DB_PASSWORD CUADRANTE_JWT_SECRET \
             SMTP_HOST SMTP_PORT SMTP_USERNAME CUADRANTE_SMTP_PASSWORD; do
        if ! grep -q "^${v}=..*" .env; then
            echo "ERROR: falta $v en .env, o está vacío. Ejecuta antes preparar-cuadrante.sh" >&2
            exit 1
        fi
    done
    echo "  las ocho variables están."
fi

# ---------- 2. Traer el código ----------
# El repositorio se llama cuadrante_backend (guion bajo), pero el directorio DEBE ser
# cuadrante-backend (guion medio): es lo que dice 'build:' en el compose.
traer() {
    local repo=$1 directorio=$2
    if [ -d "$directorio/.git" ]; then
        echo "== Actualizando $directorio =="
        git -C "$directorio" pull --ff-only
    else
        echo "== Clonando $directorio =="
        if ! git clone "$repo" "$directorio"; then
            echo >&2
            echo "ERROR al clonar $repo. Es privado: el VPS necesita su clave de despliegue." >&2
            echo "Prueba la conexión:  ssh -T ${repo%%:*}   (debe saludar: «successfully authenticated»)" >&2
            exit 1
        fi
    fi
    echo "  en el commit: $(git -C "$directorio" log --oneline -1)"
}

servicios=()
if [ "$QUE" != web ]; then traer "$REPO_API" cuadrante-backend;  servicios+=(cuadrante-api); fi
if [ "$QUE" != api ]; then traer "$REPO_WEB" cuadrante-frontend; servicios+=(cuadrante-web); fi

# ---------- 3. Construir y levantar ----------
echo "== Construyendo y levantando ${servicios[*]} (la primera vez tarda varios minutos) =="
docker compose up -d --build "${servicios[@]}"

# ---------- 4. Esperar a que la API esté sana ----------
# La web no tiene healthcheck: es un Caddy sirviendo ficheros, y se comprueba por HTTPS al final.
if [ "$QUE" != web ]; then
    echo -n "== Esperando a que cuadrante-api esté sana "
    ID=$(docker compose ps -q cuadrante-api)
    ESTADO=desconocido
    for i in $(seq 1 60); do
        ESTADO=$(docker inspect -f '{{.State.Health.Status}}' "$ID" 2>/dev/null || echo desconocido)
        [ "$ESTADO" = healthy ] && { echo " -> $ESTADO"; break; }
        [ "$ESTADO" = unhealthy ] && { echo " -> $ESTADO"; break; }
        echo -n "."; sleep 5
    done
    if [ "$ESTADO" != healthy ]; then
        echo
        echo "NO está sana. Últimas líneas del log:" >&2
        docker compose logs --tail 40 cuadrante-api >&2
        exit 1
    fi
fi

# ---------- 5. Reiniciar Caddy para que sirva los sitios nuevos ----------
# REINICIAR y no recargar: 'git pull' reemplaza el Caddyfile (cambia el inode) y el
# contenedor seguiría leyendo el viejo sin dar ningún error (§13.4 de gastos, pagada dos veces).
echo "== Reiniciando Caddy (corta el blog y gastos unos segundos) =="
docker compose restart caddy
sleep 3

# Espera a que una URL dé el código esperado (el primer certificado puede tardar).
esperar() {
    local url=$1 esperado=$2 codigo=000
    for i in $(seq 1 12); do
        codigo=$(curl -sS -o /dev/null -w '%{http_code}' "$url" 2>/dev/null) || codigo=000
        [ "$codigo" = "$esperado" ] && break
        sleep 5
    done
    echo "$codigo"
}

# ---------- 6. Comprobar de extremo a extremo ----------
echo
echo "===== COMPROBACIÓN ====="

if [ "$QUE" != web ]; then
    echo "-- Flyway (debe haber aplicado 15 migraciones la primera vez, o validado 15 después) --"
    docker compose logs cuadrante-api 2>/dev/null | grep -i "Successfully applied\|Successfully validated" | tail -2 \
        || echo "  (sin líneas de Flyway)"

    echo "-- Tablas creadas --"
    docker compose exec -T db sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysql -uroot -N -e "
    SELECT COUNT(*) FROM information_schema.tables WHERE table_schema=\"cuadrante\";"' \
        | xargs -I{} echo "  {} tablas (deben ser 10: las 9 del modelo + flyway_schema_history)"

    CODIGO=$(esperar "https://$DOMINIO_API/actuator/health" 200)
    echo "  https://$DOMINIO_API/actuator/health -> $CODIGO   (debe ser 200)"
    if [ "$CODIGO" != 200 ]; then
        echo "  Si es 000 con 'tlsv1 alert internal error', Caddy no tiene certificado para ese nombre."
        echo "  Comprueba que el bloque está cargado:  docker compose exec -T caddy grep -n cuadrante /etc/caddy/Caddyfile"
        echo "  y qué dice del certificado:            docker compose logs caddy --tail 60 | grep -i acme"
    fi

    echo "-- Sin token, la API debe rechazar con ProblemDetail --"
    curl -sS -o /dev/null -w "  /api/auth/me -> %{http_code}   (debe ser 401)\n" "https://$DOMINIO_API/api/auth/me" || true

    # Lección de gastos (§10 de cuadrante): con curl todo funciona aunque CORS esté mal;
    # el navegador hace antes este sondeo, y sin la cabecera de vuelta lo rechaza.
    echo "-- Sondeo CORS desde la web, como lo haría el navegador --"
    PERMITIDO=$(curl -sS -o /dev/null -D - -X OPTIONS "https://$DOMINIO_API/api/auth/login" \
        -H "Origin: https://$DOMINIO_WEB" -H "Access-Control-Request-Method: POST" \
        -H "Access-Control-Request-Headers: content-type" \
        | tr -d '\r' | grep -i '^access-control-allow-origin:' | cut -d' ' -f2- || true)
    echo "  Access-Control-Allow-Origin: ${PERMITIDO:-(ninguna)}   (debe ser https://$DOMINIO_WEB)"
fi

if [ "$QUE" != api ]; then
    CODIGO=$(esperar "https://$DOMINIO_WEB/" 200)
    echo "  https://$DOMINIO_WEB/ -> $CODIGO   (debe ser 200)"

    echo "-- Es el Angular de cuadrante, y no otro --"
    if curl -sS "https://$DOMINIO_WEB/" | grep -q '<app-root'; then
        echo "  el index.html trae <app-root>: correcto"
    else
        echo "  ATENCIÓN: el index.html no trae <app-root>"
    fi

    # Angular resuelve las rutas en el navegador: recargar en una ruta interna no debe dar 404.
    curl -sS -o /dev/null -w "  /login (ruta interna) -> %{http_code}   (debe ser 200)\n" "https://$DOMINIO_WEB/login" || true

    echo "-- El index.html no se cachea (si no, una versión nueva no llegaría) --"
    curl -sS -o /dev/null -D - "https://$DOMINIO_WEB/" | tr -d '\r' | grep -i '^cache-control:' \
        | sed 's/^/  /' || echo "  (sin Cache-Control)"
fi

echo
echo "Listo."
if [ "$QUE" != web ]; then
    echo "Las dos cuentas arrancan SIN contraseña (V9). Para entrar: «¿Has olvidado la contraseña?»"
    echo "con tu correo provisional. Si el código no llega, mira:  docker compose logs cuadrante-api | grep -i mail"
fi
