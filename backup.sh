#!/usr/bin/env bash
#
# Backup del blog: volcado de MySQL + tar de las imágenes subidas.
# Se ejecuta desde cron. No contiene secretos: los lee del entorno
# de los propios contenedores.

set -euo pipefail

PROYECTO=/opt/blog
DESTINO=/var/backups/blog
RETENCION=14                       # días que se conservan
FECHA=$(date +%F_%H%M)             # p.ej. 2026-08-23_0330

cd "$PROYECTO"

echo "===== $(date '+%F %T') — inicio del backup ====="

# ---------- 1. Base de datos ----------
TMP_DB="$DESTINO/db-$FECHA.sql.gz.parcial"

docker compose exec -T db sh -c '
    MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysqldump -uroot \
        --single-transaction \
        --no-tablespaces \
        --default-character-set=utf8mb4 \
        "$MYSQL_DATABASE"
' | gzip > "$TMP_DB"

# Un fichero de 20 bytes es un gzip vacío: eso NO es un backup.
if [ "$(stat -c%s "$TMP_DB")" -lt 1000 ]; then
    echo "ERROR: el volcado de la base de datos está vacío"
    rm -f "$TMP_DB"
    exit 1
fi
mv "$TMP_DB" "$DESTINO/db-$FECHA.sql.gz"

# ---------- 2. Base de datos de gastos ----------
# Base aparte, usuario aparte, volcado aparte: si un día se restaura una,
# no arrastra la otra.
TMP_GASTOS="$DESTINO/gastos-$FECHA.sql.gz.parcial"

docker compose exec -T db sh -c '
    MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysqldump -uroot \
        --single-transaction \
        --no-tablespaces \
        --default-character-set=utf8mb4 \
        gastos
' | gzip > "$TMP_GASTOS"

# 473 gastos ocupan ~11 KB comprimidos. Menos de 5 KB es un volcado incompleto.
if [ "$(stat -c%s "$TMP_GASTOS")" -lt 5000 ]; then
    echo "ERROR: el volcado de 'gastos' está vacío o incompleto"
    rm -f "$TMP_GASTOS"
    exit 1
fi
mv "$TMP_GASTOS" "$DESTINO/gastos-$FECHA.sql.gz"

# ---------- 3. Base de datos de cuadrante ----------
# Como gastos: base, usuario y fichero propios. Lleva datos de un cliente (los turnos y
# los nombres de sus recepcionistas, y las cuentas con sus correos y hashes).
TMP_CUAD="$DESTINO/cuadrante-$FECHA.sql.gz.parcial"

docker compose exec -T db sh -c '
    MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysqldump -uroot \
        --single-transaction \
        --no-tablespaces \
        --default-character-set=utf8mb4 \
        cuadrante
' | gzip > "$TMP_CUAD"

# Aquí el tamaño no sirve de guardián: el esquema vacío ya ocupa ~2 KB comprimido, casi lo
# mismo que la base recién desplegada (~2,7 KB). Se mira el contenido: que mysqldump llegó
# al final (su última línea es «-- Dump completed») y que están las tres tablas que nunca
# están vacías: las migraciones, las cuentas (V9) y el catálogo de códigos (V4).
FIN=$(zcat "$TMP_CUAD" | tail -n 1)
TABLAS=$(zcat "$TMP_CUAD" | grep -o -E '^INSERT INTO `(flyway_schema_history|usuario|codigo)`' \
    | sort -u | wc -l || true)
if [[ "$FIN" != "-- Dump completed"* ]] || [ "$TABLAS" -ne 3 ]; then
    echo "ERROR: el volcado de 'cuadrante' está incompleto (final: '$FIN'; tablas clave: $TABLAS de 3)"
    rm -f "$TMP_CUAD"
    exit 1
fi
mv "$TMP_CUAD" "$DESTINO/cuadrante-$FECHA.sql.gz"

# ---------- 4. Imágenes subidas ----------
TMP_UP="$DESTINO/uploads-$FECHA.tar.gz.parcial"

docker compose exec -T backend tar czf - -C /app/uploads . > "$TMP_UP"

if [ "$(stat -c%s "$TMP_UP")" -lt 1000 ]; then
    echo "ERROR: el archivo de imágenes está vacío"
    rm -f "$TMP_UP"
    exit 1
fi
mv "$TMP_UP" "$DESTINO/uploads-$FECHA.tar.gz"

# ---------- 5. Rotación ----------
find "$DESTINO" -type f \( -name '*.gz' -o -name '*.parcial' \) \
     -mtime +"$RETENCION" -delete

echo "OK — $(ls -1 "$DESTINO"/*.gz | wc -l) copias en $DESTINO"
ls -lh "$DESTINO/db-$FECHA.sql.gz" "$DESTINO/gastos-$FECHA.sql.gz" \
      "$DESTINO/cuadrante-$FECHA.sql.gz" "$DESTINO/uploads-$FECHA.tar.gz"

