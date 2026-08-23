# Backups del blog

Cómo se respalda `taller-barataria.io`, cómo comprobarlo y cómo restaurar.

Complementa a [DESPLIEGUE.md](DESPLIEGUE.md). El script es [`backup.sh`](backup.sh), en este
mismo repositorio.

---

## Qué se respalda

| | Dónde vive | Cómo se respalda |
|---|---|---|
| Posts, usuarios, categorías, comentarios | volumen `blog_db_data` | `mysqldump` comprimido |
| Imágenes subidas | volumen `blog_uploads` | `tar.gz` |
| Código del backend y del frontend | GitHub | ya está en git |
| `docker-compose.yml`, `Caddyfile`, `backup.sh` | GitHub (`blog-despliegue`) | ya está en git |
| **`.env`** (credenciales de producción) | **solo el VPS** | **nada lo respalda** |

Ese último es el punto débil deliberado: no puede estar en un repositorio público. Sus seis
variables están documentadas en `.env.example`; los valores se regeneran con
`openssl rand -base64 24` si hiciera falta. Cambiarlos **no** invalida ningún dato — solo obliga
a volver a hacer login, porque cambia la clave JWT.

---

## El día a día

```bash
# --- En el VPS ---
cd /opt/blog

./backup.sh                        # lanzar una copia AHORA
cat /var/backups/blog/backup.log   # qué hicieron las copias automáticas
ls -lh /var/backups/blog/          # las copias que hay, 14 días de retención

# --- Desde la WSL ---
rsync -avz --delete deploy@77.37.122.44:/var/backups/blog/ ~/backups-blog/
```

### `./backup.sh` — lanzar una copia a mano

Lo mismo que hace el cron, pero cuando tú quieras. **Ejecútalo siempre antes de un despliegue que
toque una clase con `@Entity`**: `ddl-auto=update` modifica las tablas al arrancar el backend y
algunos cambios no tienen vuelta atrás.

Tarda unos segundos y no interrumpe el servicio: `mysqldump --single-transaction` vuelca desde un
instante congelado mientras el blog sigue atendiendo visitas.

### `cat /var/backups/blog/backup.log` — vigilar las copias automáticas

**El comando más importante de esta página.** Un backup automático que falla en silencio es peor
que no tener backup, porque crees que estás cubierto.

Cada ejecución añade su fecha, un `OK` y el tamaño de los dos ficheros. Si ves `ERROR`, o si la
última línea es de hace días, algo se rompió. Míralo de vez en cuando.

### `ls -lh /var/backups/blog/` — ver qué copias hay

```
db-2026-08-23_0330.sql.gz        ~60 KB
uploads-2026-08-23_0330.tar.gz   ~4,3 MB
```

Dos ficheros por día, catorce días. Si el `.sql.gz` bajara a unos pocos cientos de bytes, sería
un volcado vacío: el script aborta antes de guardar algo así, pero conviene mirarlo.

**Aquí no aparece nunca un fichero a medio escribir.** El script escribe en `.parcial` y solo
renombra al terminar, y el renombrado es atómico. Así la rotación no puede borrar la copia buena
dejándote una corrupta con buen nombre.

### `rsync` — sacar las copias del VPS

**Un backup que vive en la misma máquina que protege no es un backup.** Si el disco del VPS se
corrompe o borras el servidor por error, las copias se van con él.

- `-a` conserva permisos y fechas, `-z` comprime en tránsito, `-v` muestra qué transfiere.
- `--delete` hace de tu carpeta un espejo exacto: lo que la rotación borró en el VPS desaparece
  aquí también, y así `~/backups-blog/` no crece sin control.
- Solo transfiere lo que falta, así que a partir de la segunda vez tarda un segundo.

Pide la passphrase de la clave SSH, **y por eso no está automatizado**: una clave sin passphrase
en un cron sería una llave permanente al servidor guardada en el disco de un escritorio.
Ejecútalo a mano una vez por semana; con catorce días de retención en el VPS hay margen de sobra.

---

## Las copias automáticas

En el crontab del usuario `deploy` del VPS (`crontab -l`):

```cron
MAILTO=""
30 3 * * * /opt/blog/backup.sh >> /var/backups/blog/backup.log 2>&1
```

Todos los días a las **03:30, hora del servidor**. El `2>&1` manda también los errores al log —
sin él se perderían, que es justo lo que necesitas ver.

Destino: `/var/backups/blog`, permisos **700**, propiedad de `deploy`.

- **Fuera de `/opt/blog`**: si algún día borras la carpeta del proyecto, las copias no se van con ella.
- **700** porque el volcado contiene la tabla `usuarios` con sus hashes BCrypt y todos tus posts.

---

## Cómo restaurar de verdad

### La base de datos

```bash
cd /opt/blog
docker compose stop backend        # que nadie escriba mientras restauras

gunzip -c /var/backups/blog/db-2026-08-23_0330.sql.gz | \
docker compose exec -T db sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot "$MYSQL_DATABASE"'

docker compose start backend
```

El volcado lleva `DROP TABLE IF EXISTS` antes de cada `CREATE TABLE`, así que **sustituye** las
tablas en vez de mezclarse con lo que hubiera. Lo que haya llegado después de la fecha del backup
se pierde: eso es lo que significa restaurar.

### Las imágenes

```bash
docker compose exec -T backend tar xzf - -C /app/uploads \
    < /var/backups/blog/uploads-2026-08-23_0330.tar.gz
```

El `-T` es imprescindible: sin él Docker asigna una pseudo-terminal, traduce saltos de línea y
corrompe el flujo binario del `.tar.gz`.

### Desde cero, tras perder el VPS

1. Servidor nuevo con Docker (`Fase 6` del plan).
2. `git clone` de `blog-despliegue` en `/opt/blog`, y dentro, `blog` y `auto-blog`.
3. Reconstruir el `.env` a partir de `.env.example` con credenciales nuevas.
4. `docker compose up -d --build`.
5. Restaurar la base de datos y las imágenes con los dos comandos de arriba.
6. Apuntar el DNS a la IP nueva.

---

## Comprobar que un backup sirve, sin tocar producción

Tener ficheros no es tener backups. Esto restaura en una base de datos de usar y tirar y cuenta
lo que ha llegado:

```bash
cd /opt/blog

docker compose exec -T db sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot \
    -e "DROP DATABASE IF EXISTS ensayo; CREATE DATABASE ensayo"'

gunzip -c /var/backups/blog/db-2026-08-23_0330.sql.gz | \
docker compose exec -T db sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot ensayo'

docker compose exec -T db sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot ensayo \
    -e "SELECT COUNT(*) AS posts FROM posts; SELECT COUNT(*) AS usuarios FROM usuarios"'

docker compose exec -T db sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot \
    -e "DROP DATABASE ensayo"'
```

Funciona porque el volcado se hace **sin `--databases`**: no contiene `CREATE DATABASE` ni `USE`,
solo tablas, y por eso puede importarse en una base con otro nombre. Con `--databases` el fichero
se empeñaría en escribir sobre `blog` ignorando el nombre que le das, y el «ensayo» sería una
restauración real sobre producción.

### Ensayo verificado el 2026-08-23

Se restauró el backup del VPS en un `mysql:8.4.9` recién creado **en la WSL**, desde la copia
traída por `rsync` — es decir, otra máquina, otro servidor MySQL, y el fichero después de viajar
por la red. Resultado:

```
posts 56 · usuarios 4 · categorias 10 · post_categoria 72 · post_favoritos 4 · comentarios 1
```

- Coincide con `"totalElements":56` de la API en producción.
- Acentos íntegros: `ó` = `C3B3`, colación `utf8mb4_spanish2_ci`.
- Las 56 `foto_url` de la base tienen su fichero en el `.tar.gz`. Cero ausencias, cero huérfanas.

---

## Por qué el script no contiene contraseñas

`backup.sh` está en un repositorio **público** y aun así no filtra nada, porque nunca escribe una
credencial:

```bash
docker compose exec -T db sh -c '
    MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysqldump -uroot ... "$MYSQL_DATABASE"
'
```

Las **comillas simples** impiden que el shell del VPS toque `$MYSQL_ROOT_PASSWORD`: la cadena
viaja literal hasta el `sh` de dentro del contenedor, y se expande allí, contra el entorno que
Compose le puso al arrancar. La contraseña no aparece en el script, ni en el historial de bash,
ni en la línea de órdenes del anfitrión.

Y `MYSQL_PWD=` en lugar de `-p"..."` evita que quede visible en `ps` dentro del contenedor. Es la
causa real del aviso *«Using a password on the command line interface can be insecure»*.

> Si alguna vez editas el script, **respeta las comillas simples**. Con dobles, tu shell
> intentaría expandir la variable en el VPS —donde no existe— y `set -u` mataría el script con un
> error que parece incomprensible hasta que ves por qué.

---

## Lo que este sistema NO cubre

- **El `.env`.** Reconstruible desde `.env.example`, pero no respaldado.
- **La copia fuera del VPS es manual.** Si te olvidas del `rsync` tres semanas y el servidor
  muere, pierdes lo que no llegaste a traerte.
- **Un fichero subido justo durante el `tar`** podría quedar a medias en esa copia. Riesgo
  mínimo y se corrige solo al día siguiente.
- **No hay copias mensuales de largo plazo.** La retención son 14 días: sirve para un desastre,
  no para recuperar un post que borraste hace dos meses.
