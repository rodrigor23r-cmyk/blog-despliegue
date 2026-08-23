# Desplegar un cambio en producción

Documento de apoyo para el blog de **taller-barataria.io**.
VPS: `deploy@77.37.122.44` · Proyecto Compose en `/opt/blog`

---

## Resumen rápido

| Cambiaste... | Viaja por | Comando en el VPS | Corte |
|---|---|---|---|
| Código del **backend** | git | `docker compose up -d --build backend` | ~20 s |
| Código del **frontend** | git | `docker compose up -d --build caddy` | < 1 s |
| **Caddyfile** | git | `docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile` | ninguno |
| **docker-compose.yml** | git | `docker compose up -d` | según servicio |
| **.env** | a mano | `docker compose up -d` | según servicio |

---

## El circuito

```
WSL (editas) ──git push──> GitHub ──git pull──> VPS ──docker compose build──> contenedor
```

La regla que hace esto fiable: **el código viaja por git, nunca por `scp`.**
Si copiaras ficheros sueltos al VPS, en dos semanas nadie —tú incluido— sabría qué
versión corre allí. Con git, `git log` en el VPS te lo dice siempre.

**No se sube ningún `.jar` ni ningún `dist/`.** Sube el código fuente y el VPS compila.
Por eso los `Dockerfile` llevan la etapa de build dentro.

---

## Caso A — Cambio en el backend

### En tu WSL

```bash
cd ~/vsCode-projects/blog_compendio/blog

# 1. Pruébalo en local ANTES de subir nada
SPRING_PROFILES_ACTIVE=local ./mvnw spring-boot:run

# 2. Sube el cambio
git add -A
git commit -m "Permitir HEAD además de GET en los endpoints públicos"
git push
```

### En el VPS

```bash
cd /opt/blog

# 3. Backup ANTES, si el cambio toca entidades JPA (ver el aviso de más abajo)
./backup.sh

# 4. Traer el código nuevo
cd /opt/blog/blog
git pull
git log -1 --oneline          # confirma qué commit vas a desplegar

# 5. Reconstruir y sustituir solo el backend
cd /opt/blog
docker compose up -d --build backend

# 6. Mirar que arranca bien
docker compose logs -f --tail=50 backend
```

**El paso 5 es el importante.** Al nombrar `backend` al final, Compose reconstruye esa
imagen y recrea ese contenedor; **`db` y `caddy` ni se enteran**. La base de datos no se
reinicia y los certificados no se tocan.

El orden importa: Docker **primero compila la imagen nueva y solo después cambia el
contenedor**. Mientras Maven descarga y compila —un par de minutos—, el contenedor viejo
sigue atendiendo visitas. El corte real son los ~20 segundos que tarda Spring Boot en arrancar.

Cuando veas `Started BlogApplication in X seconds`, sal con `Ctrl+C`. Eso solo cierra el
visor de logs, no el contenedor.

---

## Caso B — Cambio en el frontend

Idéntico, pero el servicio es **`caddy`**, no un servicio de frontend: el Angular compilado
vive dentro de la imagen de Caddy.

```bash
# En WSL
cd ~/vsCode-projects/blog_frontend/auto-blog
npm start                      # pruébalo en local
git add -A && git commit -m "..." && git push

# En el VPS
cd /opt/blog/auto-blog && git pull
cd /opt/blog && docker compose up -d --build caddy
```

El corte es de **menos de un segundo**. Los certificados sobreviven porque están en el
volumen `caddy_data`, no dentro de la imagen.

Los visitantes ven la versión nueva **de inmediato**, sin vaciar la caché: `index.html` va
con `no-cache`, así que el navegador siempre pregunta; y como Angular renombra el bundle
(`main-36QQVD5W.js` → otro hash), el `index.html` nuevo apunta a ficheros que nadie tiene
cacheados. Los viejos, con su `immutable`, simplemente dejan de pedirse.

---

## Caso C — Cambio en `docker-compose.yml` o en el `Caddyfile`

Estos ficheros viven en el repositorio **`blog-despliegue`**, así que viajan por git
igual que el código.

```bash
# En tu WSL
cd ~/vsCode-projects/blog_deploy
git add -A && git commit -m "..." && git push

# En el VPS
cd /opt/blog
git pull
```

Y luego, según qué tocaras:

```bash
# Si tocaste el Caddyfile: valida y recarga EN CALIENTE, sin cortar nada
docker compose exec caddy caddy validate --config /etc/caddy/Caddyfile
docker compose exec caddy caddy reload  --config /etc/caddy/Caddyfile

# Si tocaste el docker-compose.yml: recrear los servicios afectados
docker compose up -d
```

`caddy reload` carga la configuración nueva **sin cerrar ni una sola conexión en curso**.
Cero corte. El `validate` previo evita el escenario feo: recargar con una errata y quedarte
sin web.

> El `git pull` **no toca el `.env`**: está en el `.gitignore`, así que git lo ignora por
> completo. Tampoco toca `blog/` ni `auto-blog/`, ignorados por la misma razón, aunque en el
> VPS sean clones de verdad.

### Preparar el VPS la primera vez

`/opt/blog` se creó copiando ficheros a mano, así que todavía no es un clon. Hay que
convertirlo, **una sola vez**:

```bash
cd /opt/blog

# 1. Guarda lo que hay ahora, para comparar después
cp docker-compose.yml docker-compose.yml.bak
cp Caddyfile          Caddyfile.bak

# 2. Convierte la carpeta en un clon del repositorio
git init -b main
git remote add origin https://github.com/rodrigor23r-cmyk/blog-despliegue.git
git fetch origin
git reset --hard origin/main
git branch --set-upstream-to=origin/main main

# 3. Comprueba que lo que baja de GitHub es idéntico a lo que había
diff docker-compose.yml docker-compose.yml.bak && echo "compose: identico"
diff Caddyfile          Caddyfile.bak          && echo "Caddyfile: identico"

# 4. Si los dos dicen "identico", limpia
rm docker-compose.yml.bak Caddyfile.bak
ls -l .env    # sigue ahí, intacto
```

**No te saltes el paso 3.** `git reset --hard` sobrescribe los ficheros versionados con la
versión de GitHub. Si en algún momento arreglaste algo directamente en el VPS y no lo
llevaste a tu WSL, ese arreglo desaparece ahí. El `diff` te avisa antes de que sea tarde;
si sale alguna diferencia, para y decide cuál de las dos versiones es la buena.

`git reset --hard` **no borra ficheros sin seguimiento**, así que tu `.env`, `blog/` y
`auto-blog/` sobreviven.

### El `.env` es la única excepción

Nunca ha estado ni estará en git: contiene la contraseña de MySQL y la clave JWT de
producción, y el repositorio es público.

Si algún día necesitas cambiarlo, se edita **directamente en el VPS** con `nano /opt/blog/.env`,
y después `docker compose up -d` para que los contenedores recojan los valores nuevos.
Si el cambio también afecta a tu entorno local, replícalo a mano en tu `.env` de la WSL: son
dos ficheros distintos con credenciales distintas, y así deben seguir.

Cuando añadas una variable nueva, añádela también a **`.env.example`** con un valor falso.
Ese fichero sí está en git y es lo único que documenta qué variables hacen falta.

---

## Aviso: `ddl-auto=update`

Al arrancar el backend, Hibernate compara tus entidades con las tablas y las modifica para
que cuadren. Es cómodo, pero solo sabe hacer **una** cosa:

| Cambio en tu entidad | Qué hace Hibernate |
|---|---|
| Añadir un campo | Añade la columna. Bien. |
| Añadir una entidad | Crea la tabla. Bien. |
| **Renombrar un campo** | Crea una columna nueva **vacía** y deja la vieja con tus datos dentro. |
| Borrar un campo | No borra nada. |
| Cambiar el tipo de un campo | Puede fallar el arranque, o truncar datos. |

El tercer caso es el que muerde: la aplicación arranca sin errores, todo parece bien, y los
posts aparecen con ese campo vacío.

**Si el cambio toca una clase con `@Entity`, ejecuta `./backup.sh` antes.**

---

## Si algo sale mal: volver atrás

```bash
cd /opt/blog/blog
git log --oneline -5              # elige el commit que funcionaba
git checkout 4b0ec43
cd /opt/blog && docker compose up -d --build backend
```

Y cuando lo arregles en tu WSL y subas la corrección:

```bash
cd /opt/blog/blog && git checkout main && git pull
cd /opt/blog && docker compose up -d --build backend
```

Esto revierte **el código**. No revierte los cambios que Hibernate hizo en la base de datos
— para eso está el backup.

---

## Limpieza, cada varios despliegues

Cada reconstrucción deja atrás la imagen anterior, sin etiqueta:

```bash
docker images -f dangling=true       # míralas primero
docker image prune -f                # bórralas
```

**`prune -f` sin `-a` borra únicamente imágenes «colgantes»**, las que perdieron su etiqueta
porque una construcción nueva se quedó con el nombre. `mysql:8.4`, `caddy:2-alpine` y las
imágenes en uso están etiquetadas o referenciadas y **no las toca**.

Lo que borraría cosas de verdad es `docker image prune -a`, que elimina toda imagen sin
contenedor asociado. Esa no la uses.

---

## Los tres repositorios

| Carpeta en tu WSL | Repositorio | Carpeta en el VPS |
|---|---|---|
| `blog_compendio/blog` | `blog-compendio` | `/opt/blog/blog` |
| `blog_frontend/auto-blog` | `auto-blog-angular` | `/opt/blog/auto-blog` |
| `blog_deploy` | `blog-despliegue` | `/opt/blog` |

Los tres son públicos. Lo que **nunca** entra en ninguno de ellos:

- `/opt/blog/.env` — credenciales de producción
- `src/main/resources/application-local.properties` — credenciales de desarrollo
- `uploads/` — las imágenes; van en el backup, no en git

Un despliegue completo tras un desastre son tres `git clone`, el `.env` reconstruido a
partir de `.env.example`, y los dos ficheros del último backup.

---

## Ver el estado en el VPS

```bash
docker compose ps                          # qué corre y desde cuándo
docker compose logs -f --tail=50 backend   # logs en vivo
docker stats --no-stream                   # RAM y CPU por contenedor
```

## Backups

```bash
./backup.sh                                              # lanzar uno a mano
cat /var/backups/blog/backup.log                         # ver los automáticos (03:30 diario)
ls -lh /var/backups/blog/                                # las copias, 14 días de retención

# Desde tu WSL, traer una copia fuera del VPS
rsync -avz --delete deploy@77.37.122.44:/var/backups/blog/ ~/backups-blog/
```
