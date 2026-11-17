#!/usr/bin/env bash
#
# Ensayo de restauración de cuadrante: coge el último backup de 'cuadrante', lo restaura
# en una base DESECHABLE y lo compara con producción, tabla a tabla y dato a dato.
# NO toca la base de producción en ningún momento. Copia adaptada de ensayo-restauracion.sh
# (el de gastos).
#
#   cd /opt/blog && bash ensayo-cuadrante.sh
#
set -euo pipefail
cd "$(dirname "$0")"

ORIGEN=${ORIGEN:-/var/backups/blog}
ENSAYO=cuadrante_ensayo

[ -f docker-compose.yml ] || { echo "ERROR: no es el directorio del proyecto" >&2; exit 1; }

COPIA=$(ls -1t "$ORIGEN"/cuadrante-*.sql.gz 2>/dev/null | head -1 || true)
[ -n "$COPIA" ] || { echo "ERROR: no hay ningún cuadrante-*.sql.gz en $ORIGEN. Lanza antes backup.sh" >&2; exit 1; }
echo "Copia a ensayar: $COPIA  ($(stat -c%s "$COPIA") bytes, del $(date -r "$COPIA" '+%F %T'))"

# "$@" y no $*: ver el comentario de ensayo-restauracion.sh (con $* mysql recibe el -e partido).
sql() { docker compose exec -T db sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysql -uroot "$@"' sh "$@"; }

echo "== Creando base desechable $ENSAYO =="
sql -e "DROP DATABASE IF EXISTS $ENSAYO; CREATE DATABASE $ENSAYO CHARACTER SET utf8mb4 COLLATE utf8mb4_spanish2_ci;"

echo "== Restaurando la copia en ella =="
zcat "$COPIA" | docker compose exec -T db sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysql -uroot "$1"' sh "$ENSAYO"

# El esquema cambia con la fase 2 (V16–V19): el ensayo mira qué hay en producción y
# compara lo que exista, para que valga antes y después de desplegar. Por eso backup.sh
# y el ensayo se lanzan seguidos: la copia y producción tienen que tener el mismo esquema.
hay() { [ "$(sql -N -e "SELECT COUNT(*) FROM information_schema.$1")" -gt 0 ]; }
hay_columna() { hay "columns WHERE table_schema = 'cuadrante' AND table_name = '$1' AND column_name = '$2'"; }
hay_tabla()   { hay "tables WHERE table_schema = 'cuadrante' AND table_name = '$1'"; }

# V17 renombra quién y cuándo guardó una versión: publicada_* → guardada_* (D51).
if hay_columna version_cuadrante guardada_en; then QUIEN=guardada; else QUIEN=publicada; fi
# V16 enlaza la cuenta con su fila del cuadrante (D31).
if hay_columna usuario trabajador_id; then FILA="COALESCE(trabajador_id, '-')"; else FILA="'-'"; fi

# Cada comprobación es «nombre|consulta», con {B} en lugar de la base: se ejecuta contra
# producción y contra la copia, y tienen que dar lo mismo.
#
# Contar filas no basta: una copia con todas las filas pero un hash o un JSON cortado
# pasaría. Las «huellas» suman el CRC32 de cada fila entera, así que cualquier dato
# distinto cambia el resultado. Las versiones publicadas son lo que se firma y se conserva
# 4 años (D16): su huella incluye el JSON completo.
COMPROBACIONES=(
  "migraciones (correctas)|SELECT CONCAT(COUNT(*), ' (', SUM(success), ')') FROM {B}.flyway_schema_history"
  "cuentas|SELECT COUNT(*) FROM {B}.usuario"
  "huella de las cuentas|SELECT COALESCE(SUM(CRC32(CONCAT_WS('|', id, username, email, COALESCE(password_hash, '-'), nombre, rol, activo, version_credenciales, $FILA))), 0) FROM {B}.usuario"
  "editores (rol_editor)|SELECT COUNT(rol_editor) FROM {B}.usuario"
  "trabajadores|SELECT COUNT(*) FROM {B}.trabajador"
  "huella de trabajadores|SELECT COALESCE(SUM(CRC32(CONCAT_WS('|', id, nombre, orden, tipo, hace_noches, fecha_alta, COALESCE(fecha_salida, '-')))), 0) FROM {B}.trabajador"
  "códigos|SELECT COUNT(*) FROM {B}.codigo"
  "huella de códigos|SELECT COALESCE(SUM(CRC32(CONCAT_WS('|', id, clave, etiqueta, nombre, color_fondo, color_texto, activo, orden))), 0) FROM {B}.codigo"
  "celdas asignadas|SELECT COUNT(*) FROM {B}.asignacion"
  "huella de las celdas|SELECT COALESCE(SUM(CRC32(CONCAT_WS('|', trabajador_id, fecha, codigo_id, peticion))), 0) FROM {B}.asignacion"
  "días críticos|SELECT COUNT(*) FROM {B}.dia_critico"
  "saldos anuales|SELECT COUNT(*) FROM {B}.saldo_anual"
  "versiones guardadas|SELECT COUNT(*) FROM {B}.version_cuadrante"
  "huella de las versiones|SELECT COALESCE(SUM(CRC32(CONCAT_WS('|', anio, mes, numero, ${QUIEN}_en, ${QUIEN}_por_nombre, contenido))), 0) FROM {B}.version_cuadrante"
  "ajustes|SELECT COUNT(*) FROM {B}.ajustes"
  "códigos de verificación|SELECT COUNT(*) FROM {B}.codigo_verificacion"
)
# Las tablas de la fase 2, si ya están (V18 y V19).
if hay_tabla publicacion_version; then
    COMPROBACIONES+=(
      "versiones publicadas|SELECT COUNT(*) FROM {B}.publicacion_version"
      "huella de publicaciones|SELECT COALESCE(SUM(CRC32(CONCAT_WS('|', version_id, publicada_en, publicada_por_nombre))), 0) FROM {B}.publicacion_version"
    )
fi
if hay_tabla version_vista; then
    COMPROBACIONES+=("versiones vistas|SELECT COUNT(*) FROM {B}.version_vista")
fi
# Las peticiones de los trabajadores (V20, H9). fecha_pendiente es una columna calculada:
# mysqldump no la vuelca y MySQL la rehace al restaurar; si no, el índice que impide dos
# pendientes del mismo día (D70) dejaría de funcionar. Por eso se compara también.
if hay_tabla peticion; then
    COMPROBACIONES+=(
      "peticiones|SELECT COUNT(*) FROM {B}.peticion"
      "huella de peticiones|SELECT COALESCE(SUM(CRC32(CONCAT_WS('|', id, trabajador_id, fecha, codigo_id, COALESCE(comentario, '-'), estado, pedida_en, COALESCE(resuelta_en, '-'), COALESCE(motivo_rechazo, '-')))), 0) FROM {B}.peticion"
      "peticiones pendientes|SELECT COUNT(fecha_pendiente) FROM {B}.peticion"
    )
fi

echo
echo "===== PRODUCCIÓN frente a LA COPIA RESTAURADA ====="
printf '  %-26s %14s %14s\n' "" "producción" "copia"
DISTINTAS=0
for c in "${COMPROBACIONES[@]}"; do
    nombre=${c%%|*}
    consulta=${c#*|}
    prod=$(sql -N -e "${consulta//\{B\}/cuadrante}")
    copia=$(sql -N -e "${consulta//\{B\}/$ENSAYO}")
    marca=""
    [ "$prod" = "$copia" ] || { marca="   ✘"; DISTINTAS=$((DISTINTAS + 1)); }
    printf '  %-26s %14s %14s%s\n' "$nombre" "$prod" "$copia" "$marca"
done

# Las claves ajenas no se comprueban al restaurar (el volcado las desactiva), así que una
# copia incoherente se cargaría sin quejarse. Esto lo mira a mano.
echo "-- Integridad referencial en la copia (todo debe ser 0) --"
HUERFANOS=$(sql -N -e "
SELECT (SELECT COUNT(*) FROM $ENSAYO.asignacion a LEFT JOIN $ENSAYO.trabajador t ON t.id = a.trabajador_id WHERE t.id IS NULL)
     + (SELECT COUNT(*) FROM $ENSAYO.asignacion a LEFT JOIN $ENSAYO.codigo c ON c.id = a.codigo_id WHERE c.id IS NULL)
     + (SELECT COUNT(*) FROM $ENSAYO.saldo_anual s LEFT JOIN $ENSAYO.trabajador t ON t.id = s.trabajador_id WHERE t.id IS NULL);")
if hay_columna usuario trabajador_id; then
    HUERFANOS=$(( HUERFANOS + $(sql -N -e "SELECT COUNT(*) FROM $ENSAYO.usuario u LEFT JOIN $ENSAYO.trabajador t
        ON t.id = u.trabajador_id WHERE u.trabajador_id IS NOT NULL AND t.id IS NULL;") ))
fi
if hay_tabla peticion; then
    HUERFANOS=$(( HUERFANOS + $(sql -N -e "SELECT COUNT(*) FROM $ENSAYO.peticion p LEFT JOIN $ENSAYO.trabajador t
        ON t.id = p.trabajador_id WHERE t.id IS NULL;") ))
fi
if hay_tabla publicacion_version; then
    HUERFANOS=$(( HUERFANOS + $(sql -N -e "SELECT COUNT(*) FROM $ENSAYO.publicacion_version p LEFT JOIN $ENSAYO.version_cuadrante v
        ON v.id = p.version_id WHERE v.id IS NULL;") ))
fi
echo "   celdas, saldos, cuentas, publicaciones o peticiones que apuntan a algo inexistente: $HUERFANOS"

# Una tabla restaurada con otro cotejo ordenaría y compararía distinto los nombres con tildes.
COTEJO=$(sql -N -e "SELECT COUNT(*) FROM information_schema.tables
                    WHERE table_schema = '$ENSAYO' AND table_collation <> 'utf8mb4_spanish2_ci';")
echo "   tablas con un cotejo que no es utf8mb4_spanish2_ci: $COTEJO"

echo "-- Veredicto --"
if [ "$DISTINTAS" -eq 0 ] && [ "$HUERFANOS" -eq 0 ] && [ "$COTEJO" -eq 0 ]; then
    echo "   ✔ LA COPIA ES RESTAURABLE Y COMPLETA"
else
    echo "   ✘ LA COPIA NO COINCIDE CON PRODUCCIÓN (comprobaciones distintas: $DISTINTAS)"
    echo "     Si algo cambió en producción después de la copia, es normal: lanza backup.sh y repite."
fi

echo "== Borrando la base desechable =="
sql -e "DROP DATABASE $ENSAYO;"
echo "Ensayo terminado. Producción no se ha tocado."
