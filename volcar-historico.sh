#!/usr/bin/env bash
#
# Vuelca la base 'gastos' de tu MySQL LOCAL a un fichero, para llevarla al VPS (§12.7).
# Lee la contraseña del application-local.properties: no hay que teclearla.
#
#   bash volcar-historico.sh
#
set -euo pipefail

PROPS=${PROPS:-$HOME/vsCode-projects/gastos/gastos_backend/src/main/resources/application-local.properties}
CONTENEDOR=${CONTENEDOR:-mysql-server}
DESTINO=${DESTINO:-$HOME/gastos-historico-$(date +%F).sql.gz}

[ -f "$PROPS" ] || { echo "ERROR: no encuentro $PROPS" >&2; exit 1; }

leer() { grep -m1 "^$1=" "$PROPS" | cut -d= -f2- ; }   # -f2-: la contraseña puede llevar '='
USUARIO=$(leer DB_USER)
CLAVE=$(leer DB_PASSWORD)

[ -n "$USUARIO" ] && [ "${#CLAVE}" -ge 8 ] || {
    echo "ERROR: no he podido leer DB_USER/DB_PASSWORD del properties." >&2; exit 1; }

docker start "$CONTENEDOR" >/dev/null 2>&1 || true
for i in $(seq 1 45); do
    docker exec -e MYSQL_PWD="$CLAVE" "$CONTENEDOR" mysql -u"$USUARIO" -e "SELECT 1" >/dev/null 2>&1 && break
    sleep 2
done

echo "== Recuento ANTES de volcar =="
docker exec -e MYSQL_PWD="$CLAVE" "$CONTENEDOR" mysql -u"$USUARIO" gastos -t -e "
SELECT (SELECT COUNT(*) FROM gasto) AS gastos,
       (SELECT COUNT(*) FROM liquidacion) AS liquidaciones,
       (SELECT COUNT(*) FROM tienda) AS tiendas,
       (SELECT FORMAT(SUM(total),2) FROM gasto) AS suma_total;" 2>/dev/null

echo "== Volcando =="
# --add-drop-table: reemplaza en el destino las tablas que Flyway ya creó allí.
# El volcado incluye flyway_schema_history, así que el destino queda coherente.
docker exec -e MYSQL_PWD="$CLAVE" "$CONTENEDOR" mysqldump -u"$USUARIO" \
    --single-transaction --no-tablespaces --default-character-set=utf8mb4 \
    --add-drop-table gastos 2>/dev/null | gzip > "$DESTINO"

TAM=$(stat -c%s "$DESTINO")
[ "$TAM" -gt 5000 ] || { echo "ERROR: el volcado tiene $TAM bytes. Eso no es un backup." >&2; rm -f "$DESTINO"; exit 1; }

echo
echo "Volcado: $DESTINO  ($TAM bytes)"
echo "  tablas dentro: $(zcat "$DESTINO" | grep -c '^DROP TABLE IF EXISTS')  (deben ser 6)"
echo "  filas de gasto: $(zcat "$DESTINO" | grep -c "^INSERT INTO \`gasto\`") sentencia(s) INSERT"
echo
echo "Siguiente paso, llevarlo al VPS:"
echo "  scp $DESTINO deploy@77.37.122.44:/tmp/"
echo "  ssh deploy@77.37.122.44 'cd /opt/blog && bash restaurar-historico.sh /tmp/$(basename "$DESTINO")'"
