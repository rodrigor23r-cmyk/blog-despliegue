#!/usr/bin/env bash
#
# Ensayo de restauración: coge el último backup de 'gastos', lo restaura en una
# base DESECHABLE y comprueba que los datos están completos.
# NO toca la base de producción en ningún momento.
#
#   cd /opt/blog && bash ensayo-restauracion.sh
#
set -euo pipefail
cd "$(dirname "$0")"

ORIGEN=${ORIGEN:-/var/backups/blog}
ENSAYO=gastos_ensayo

[ -f docker-compose.yml ] || { echo "ERROR: no es el directorio del proyecto" >&2; exit 1; }

COPIA=$(ls -1t "$ORIGEN"/gastos-*.sql.gz 2>/dev/null | head -1 || true)
[ -n "$COPIA" ] || { echo "ERROR: no hay ningún gastos-*.sql.gz en $ORIGEN" >&2; exit 1; }
echo "Copia a ensayar: $COPIA  ($(stat -c%s "$COPIA") bytes, del $(date -r "$COPIA" '+%F %T'))"

# Ojo con el paso de argumentos: "$@" (no $*) y el sh de dentro recibe cada argumento
# entero. Con $* se pegan todos en una cadena, el sh la vuelve a partir por espacios,
# y mysql acaba con cinco argumentos sueltos en vez de un -e: imprime su ayuda y sale 1.
sql() { docker compose exec -T db sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysql -uroot "$@"' sh "$@"; }

echo "== Creando base desechable $ENSAYO =="
sql -e "DROP DATABASE IF EXISTS $ENSAYO; CREATE DATABASE $ENSAYO CHARACTER SET utf8mb4 COLLATE utf8mb4_spanish2_ci;"

echo "== Restaurando la copia en ella =="
zcat "$COPIA" | docker compose exec -T db sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysql -uroot "$1"' sh "$ENSAYO"

echo
echo "===== PRODUCCIÓN frente a LA COPIA RESTAURADA ====="
sql -t -e "
SELECT 'gastos' AS tabla,
       (SELECT COUNT(*) FROM gastos.gasto) AS produccion,
       (SELECT COUNT(*) FROM $ENSAYO.gasto) AS copia
UNION ALL SELECT 'liquidaciones',
       (SELECT COUNT(*) FROM gastos.liquidacion), (SELECT COUNT(*) FROM $ENSAYO.liquidacion)
UNION ALL SELECT 'tiendas',
       (SELECT COUNT(*) FROM gastos.tienda), (SELECT COUNT(*) FROM $ENSAYO.tienda)
UNION ALL SELECT 'usuarios',
       (SELECT COUNT(*) FROM gastos.usuario), (SELECT COUNT(*) FROM $ENSAYO.usuario)
UNION ALL SELECT 'suma total (cent.)',
       (SELECT ROUND(SUM(total)*100) FROM gastos.gasto), (SELECT ROUND(SUM(total)*100) FROM $ENSAYO.gasto);"

echo "-- Integridad referencial en la copia --"
sql -N -e "SELECT COUNT(*) FROM $ENSAYO.gasto g LEFT JOIN $ENSAYO.tienda t ON t.id=g.tienda_id WHERE t.id IS NULL;" \
  | xargs -I{} echo "   gastos con tienda inexistente: {}   (debe ser 0)"

echo "-- Veredicto --"
IGUALES=$(sql -N -e "
SELECT (SELECT COUNT(*) FROM gastos.gasto)      = (SELECT COUNT(*) FROM $ENSAYO.gasto)
   AND (SELECT COUNT(*) FROM gastos.liquidacion) = (SELECT COUNT(*) FROM $ENSAYO.liquidacion)
   AND (SELECT COUNT(*) FROM gastos.tienda)      = (SELECT COUNT(*) FROM $ENSAYO.tienda)
   AND (SELECT ROUND(SUM(total)*100) FROM gastos.gasto) = (SELECT ROUND(SUM(total)*100) FROM $ENSAYO.gasto);")
[ "$IGUALES" = "1" ] && echo "   ✔ LA COPIA ES RESTAURABLE Y COMPLETA" || echo "   ✘ LA COPIA NO COINCIDE CON PRODUCCIÓN"

echo "== Borrando la base desechable =="
sql -e "DROP DATABASE $ENSAYO;"
echo "Ensayo terminado. Producción no se ha tocado."
