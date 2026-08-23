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

# ---------- 2. Imágenes subidas ----------
TMP_UP="$DESTINO/uploads-$FECHA.tar.gz.parcial"

docker compose exec -T backend tar czf - -C /app/uploads . > "$TMP_UP"

if [ "$(stat -c%s "$TMP_UP")" -lt 1000 ]; then
    echo "ERROR: el archivo de imágenes está vacío"
    rm -f "$TMP_UP"
    exit 1
fi
mv "$TMP_UP" "$DESTINO/uploads-$FECHA.tar.gz"

# ---------- 3. Rotación ----------
find "$DESTINO" -type f \( -name '*.gz' -o -name '*.parcial' \) \
     -mtime +"$RETENCION" -delete

echo "OK — $(ls -1 "$DESTINO"/*.gz | wc -l) copias en $DESTINO"
ls -lh "$DESTINO/db-$FECHA.sql.gz" "$DESTINO/uploads-$FECHA.tar.gz"

