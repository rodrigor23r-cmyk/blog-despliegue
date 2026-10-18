#!/usr/bin/env bash
#
# Prepara la base de datos y las variables de entorno de 'cuadrante', y las del
# correo común (Brevo, D49 de cuadrante). Copia adaptada de preparar-gastos.sh.
# Se ejecuta UNA vez en el VPS, pero es idempotente: relanzarlo es seguro.
#
#   cd /opt/blog && bash preparar-cuadrante.sh
#
# Para cambiar después el usuario o la clave SMTP (por ejemplo, si se anula la
# clave en Brevo), relanzarlo así:
#
#   CAMBIAR_CORREO=1 bash preparar-cuadrante.sh
#
set -euo pipefail

cd "$(dirname "$0")"

if [ ! -f docker-compose.yml ] || [ ! -f .env ]; then
    echo "ERROR: aquí no están docker-compose.yml y .env. ¿Es este el directorio del proyecto?" >&2
    exit 1
fi

# La clave SMTP se teclea: sin terminal (por ejemplo, desde cron o con una tubería) no hay dónde.
if [ ! -t 0 ]; then
    echo "ERROR: este script pregunta por teclado. Ejecútalo directamente en la terminal." >&2
    exit 1
fi

cp -p .env ".env.copia-$(date +%F_%H%M%S)"
echo "Copia de .env hecha."

# Lee el valor actual de una variable del .env, o nada si no está.
# cut -f2- y no -f2: una contraseña base64 termina en '=', que es el separador.
leer() {
    grep -m1 "^$1=" .env 2>/dev/null | cut -d= -f2- || true
}

# ---------- 1. Recuperar o generar los secretos de la base y del JWT ----------
actual=$(leer CUADRANTE_DB_PASSWORD)

if [ "${#actual}" -ge 16 ]; then
    echo "En .env ya hay una contraseña de ${#actual} caracteres: se conserva."
    clave="$actual"
else
    echo "No hay contraseña utilizable en .env (${#actual} caracteres): se genera una."
    clave=$(openssl rand -base64 24)
fi

# Nunca escribir un valor vacío.
if [ "${#clave}" -lt 16 ]; then
    echo "ERROR: la contraseña ha salido vacía o demasiado corta. No se escribe nada." >&2
    exit 1
fi

secreto=$(leer CUADRANTE_JWT_SECRET)
if [ "${#secreto}" -lt 40 ]; then
    secreto=$(openssl rand -base64 64 | tr -d '\n')
fi

# ---------- 2. El correo: común (servidor y usuario) y propio (la clave) ----------
smtp_host=$(leer SMTP_HOST)
smtp_puerto=$(leer SMTP_PORT)
smtp_usuario=$(leer SMTP_USERNAME)
smtp_clave=$(leer CUADRANTE_SMTP_PASSWORD)

[ -n "$smtp_host" ]   || smtp_host=smtp-relay.brevo.com
[ -n "$smtp_puerto" ] || smtp_puerto=587

cambiar=${CAMBIAR_CORREO:-0}

# Lo que no puede llevar un valor del .env: Docker Compose interpreta '$' como
# variable, y las comillas, '#' o los espacios cambian dónde termina el valor.
valor_seguro() {
    case "$1" in
        *'$'* | *'"'* | *"'"* | *'#'* | *' '* | *$'\t'*) return 1 ;;
    esac
}

if [ "$cambiar" = 1 ] || [ -z "$smtp_usuario" ] || [[ "$smtp_usuario" != *@* ]]; then
    echo
    echo "Usuario SMTP de Brevo: está en Brevo → SMTP y API → SMTP (algo como xxxx@smtp-brevo.com)."
    read -r -p "Usuario SMTP: " smtp_usuario
    if [[ "$smtp_usuario" != *@* ]] || ! valor_seguro "$smtp_usuario"; then
        echo "ERROR: eso no parece un usuario SMTP (debe tener una @ y ningún espacio). No se escribe nada." >&2
        exit 1
    fi
else
    echo "En .env ya hay un usuario SMTP: se conserva."
fi

if [ "$cambiar" = 1 ] || [ "${#smtp_clave}" -lt 20 ]; then
    echo
    echo "Clave SMTP 'cuadrante-prod' de Brevo. NO se verá al pegarla: es normal."
    read -r -s -p "Clave SMTP: " smtp_clave;    echo
    read -r -s -p "Otra vez:   " repetida;      echo
    if [ "$smtp_clave" != "$repetida" ]; then
        echo "ERROR: las dos claves no coinciden. No se escribe nada." >&2
        exit 1
    fi
    if [ "${#smtp_clave}" -lt 20 ] || ! valor_seguro "$smtp_clave"; then
        echo "ERROR: la clave está vacía, es demasiado corta (${#smtp_clave}) o lleva \$, comillas, # o espacios." >&2
        exit 1
    fi
    unset repetida
else
    echo "En .env ya hay una clave SMTP de ${#smtp_clave} caracteres: se conserva."
fi

# ---------- 3. Escribir las variables SIN duplicar líneas ----------
poner() {
    local nombre=$1 valor=$2
    if grep -q "^${nombre}=" .env; then
        grep -v "^${nombre}=" .env > .env.tmp && mv .env.tmp .env
    fi
    printf '%s=%s\n' "$nombre" "$valor" >> .env
}

poner SMTP_HOST                 "$smtp_host"
poner SMTP_PORT                 "$smtp_puerto"
poner SMTP_USERNAME             "$smtp_usuario"
poner CUADRANTE_DB_USER         cuadrante_user
poner CUADRANTE_DB_PASSWORD     "$clave"
poner CUADRANTE_JWT_SECRET      "$secreto"
poner CUADRANTE_SMTP_PASSWORD   "$smtp_clave"
chmod 600 .env
unset smtp_clave
echo "Variables escritas en .env (una línea por clave)."

# ---------- 4. Base de datos y usuario, idempotente ----------
# CREATE DATABASE IF NOT EXISTS no corrige el cotejo de una base ya creada:
# por eso va también el ALTER DATABASE.
docker compose exec -T db sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysql -uroot' <<SQL
CREATE DATABASE IF NOT EXISTS cuadrante CHARACTER SET utf8mb4 COLLATE utf8mb4_spanish2_ci;
ALTER DATABASE cuadrante CHARACTER SET utf8mb4 COLLATE utf8mb4_spanish2_ci;
CREATE USER IF NOT EXISTS 'cuadrante_user'@'%' IDENTIFIED BY '$clave';
ALTER USER 'cuadrante_user'@'%' IDENTIFIED BY '$clave';
GRANT ALL PRIVILEGES ON cuadrante.* TO 'cuadrante_user'@'%';
FLUSH PRIVILEGES;
SQL
echo "Base de datos y usuario en su sitio."

# ---------- 5. Comprobar ----------
echo
echo "===== COMPROBACIÓN ====="
docker compose exec -T db sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysql -uroot -t' <<'SQL'
SELECT schema_name AS base, default_collation_name AS cotejo
  FROM information_schema.schemata WHERE schema_name = 'cuadrante';
SELECT user, host FROM mysql.user WHERE user = 'cuadrante_user';
SELECT COUNT(*) AS tablas_en_cuadrante
  FROM information_schema.tables WHERE table_schema = 'cuadrante';
SQL

echo "--- ¿conecta cuadrante_user con la contraseña del .env? ---"
docker compose exec -T -e MYSQL_PWD="$clave" db mysql -ucuadrante_user -h 127.0.0.1 -t -e "SHOW DATABASES;"

echo
echo "--- líneas SMTP_* y CUADRANTE_* del .env (los valores se ocultan) ---"
grep -E '^(SMTP_|CUADRANTE_)' .env | sed 's/=.*/=(oculto)/'
for v in SMTP_USERNAME CUADRANTE_DB_PASSWORD CUADRANTE_SMTP_PASSWORD; do
    echo "apariciones de $v: $(grep -c "^$v=" .env)  (debe ser 1)"
done
echo
echo "Listo."
