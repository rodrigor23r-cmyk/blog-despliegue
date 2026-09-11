#!/usr/bin/env bash
#
# Restaura en el VPS el volcado del histórico (§12.7).
#
#   cd /opt/blog && bash restaurar-historico.sh /tmp/gastos-historico-2026-09-11.sql.gz
#
set -euo pipefail
cd "$(dirname "$0")"

VOLCADO=${1:-}
[ -n "$VOLCADO" ] && [ -f "$VOLCADO" ] || { echo "Uso: bash restaurar-historico.sh <fichero.sql.gz>" >&2; exit 1; }
[ -f docker-compose.yml ] || { echo "ERROR: no es el directorio del proyecto" >&2; exit 1; }

echo "== Copia de seguridad de lo que hay AHORA en producción =="
ANTES="/tmp/gastos-antes-de-restaurar-$(date +%F_%H%M%S).sql.gz"
docker compose exec -T db sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysqldump -uroot \
    --single-transaction --no-tablespaces --default-character-set=utf8mb4 gastos' | gzip > "$ANTES"
echo "  guardada en $ANTES ($(stat -c%s "$ANTES") bytes)"

echo "== Estado ANTES =="
docker compose exec -T db sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysql -uroot -t -e "
SELECT (SELECT COUNT(*) FROM gastos.gasto) AS gastos,
       (SELECT COUNT(*) FROM gastos.liquidacion) AS liquidaciones,
       (SELECT COUNT(*) FROM gastos.tienda) AS tiendas;"'

echo "== Restaurando =="
zcat "$VOLCADO" | docker compose exec -T db sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysql -uroot gastos'

echo "== Estado DESPUÉS (§12.6: 473 gastos, 11 liquidaciones, 32 tiendas) =="
docker compose exec -T db sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysql -uroot -t -e "
SELECT (SELECT COUNT(*) FROM gastos.gasto) AS gastos,
       (SELECT COUNT(*) FROM gastos.liquidacion) AS liquidaciones,
       (SELECT COUNT(*) FROM gastos.tienda) AS tiendas;
SELECT u.nombre, FORMAT(SUM(g.total),2) AS pagado
  FROM gastos.gasto g JOIN gastos.usuario u ON u.id=g.pagador_id GROUP BY u.nombre;
SELECT COUNT(*) AS gastos_con_tienda_inexistente
  FROM gastos.gasto g LEFT JOIN gastos.tienda t ON t.id=g.tienda_id WHERE t.id IS NULL;"'

echo "== Reiniciando gastos-api para que recargue =="
docker compose restart gastos-api
sleep 8
echo
echo "Ahora comprueba el saldo con tu usuario:"
echo "  T=\$(curl -s -X POST https://api.gastos.taller-barataria.io/api/auth/login \\"
echo "      -H 'Content-Type: application/json' -d '{\"username\":\"rodrigo\",\"password\":\"TU-CLAVE\"}' \\"
echo "      | python3 -c \"import json,sys;print(json.load(sys.stdin)['token'])\")"
echo "  curl -s https://api.gastos.taller-barataria.io/api/saldo -H \"Authorization: Bearer \$T\" | python3 -m json.tool"
echo
echo "Debe decir: Ernesto debe a Rodrigo 125,21 EUR"
