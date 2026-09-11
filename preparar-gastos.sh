#!/usr/bin/env bash
#
# Prepara la base de datos y las variables de entorno de 'gastos'.
# Se ejecuta UNA vez en el VPS, pero es idempotente: relanzarlo es seguro.
#
#   cd /opt/blog && bash preparar-gastos.sh
#
set -euo pipefail

cd "$(dirname "$0")"

if [ ! -f docker-compose.yml ] || [ ! -f .env ]; then
    echo "ERROR: aquí no están docker-compose.yml y .env. ¿Es este el directorio del proyecto?" >&2
    exit 1
fi

cp -p .env ".env.copia-$(date +%F_%H%M%S)"
echo "Copia de .env hecha."

# ---------- 1. Recuperar o generar los secretos ----------
# cut -f2- y no -f2: una contraseña base64 termina en '=', que es el separador.
actual=$(grep -m1 '^GASTOS_DB_PASSWORD=' .env 2>/dev/null | cut -d= -f2- || true)

if [ "${#actual}" -ge 16 ]; then
    echo "En .env ya hay una contraseña de ${#actual} caracteres: se conserva."
    clave="$actual"
else
    echo "No hay contraseña utilizable en .env (${#actual} caracteres): se genera una."
    clave=$(openssl rand -base64 24)
fi

# La comprobación que faltaba: nunca escribir un valor vacío.
if [ "${#clave}" -lt 16 ]; then
    echo "ERROR: la contraseña ha salido vacía o demasiado corta. No se escribe nada." >&2
    exit 1
fi

secreto=$(grep -m1 '^GASTOS_JWT_SECRET=' .env 2>/dev/null | cut -d= -f2- || true)
if [ "${#secreto}" -lt 40 ]; then
    secreto=$(openssl rand -base64 64 | tr -d '\n')
fi

# ---------- 2. Escribir las variables SIN duplicar líneas ----------
poner() {
    local nombre=$1 valor=$2
    if grep -q "^${nombre}=" .env; then
        grep -v "^${nombre}=" .env > .env.tmp && mv .env.tmp .env
    fi
    printf '%s=%s\n' "$nombre" "$valor" >> .env
}

poner GASTOS_DB_USER      gastos_user
poner GASTOS_DB_PASSWORD  "$clave"
poner GASTOS_JWT_SECRET   "$secreto"
chmod 600 .env
echo "Variables escritas en .env (una línea por clave)."

# ---------- 3. Base de datos y usuario, idempotente ----------
# CREATE DATABASE IF NOT EXISTS no corrige el cotejo de una base ya creada:
# por eso va también el ALTER DATABASE.
docker compose exec -T db sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysql -uroot' <<SQL
CREATE DATABASE IF NOT EXISTS gastos CHARACTER SET utf8mb4 COLLATE utf8mb4_spanish2_ci;
ALTER DATABASE gastos CHARACTER SET utf8mb4 COLLATE utf8mb4_spanish2_ci;
CREATE USER IF NOT EXISTS 'gastos_user'@'%' IDENTIFIED BY '$clave';
ALTER USER 'gastos_user'@'%' IDENTIFIED BY '$clave';
GRANT ALL PRIVILEGES ON gastos.* TO 'gastos_user'@'%';
FLUSH PRIVILEGES;
SQL
echo "Base de datos y usuario en su sitio."

# ---------- 4. Comprobar ----------
echo
echo "===== COMPROBACIÓN ====="
docker compose exec -T db sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysql -uroot -t' <<'SQL'
SELECT schema_name AS base, default_collation_name AS cotejo
  FROM information_schema.schemata WHERE schema_name = 'gastos';
SELECT user, host FROM mysql.user WHERE user = 'gastos_user';
SELECT COUNT(*) AS tablas_en_gastos
  FROM information_schema.tables WHERE table_schema = 'gastos';
SQL

echo "--- ¿conecta gastos_user con la contraseña del .env? ---"
docker compose exec -T -e MYSQL_PWD="$clave" db mysql -ugastos_user -h 127.0.0.1 -t -e "SHOW DATABASES;"

echo
echo "--- líneas GASTOS_* del .env (los valores se ocultan) ---"
grep '^GASTOS_' .env | sed 's/=.*/=(oculto)/'
echo "apariciones de GASTOS_DB_PASSWORD: $(grep -c '^GASTOS_DB_PASSWORD=' .env)  (debe ser 1)"
echo
echo "Listo."
