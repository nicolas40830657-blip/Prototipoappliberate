# Liberate · Cómo poner en marcha Supabase

Guía paso a paso para crear la base de datos y conectar la app.

## 0. Qué cuenta usar

Usá el **mail de Liberate** para todo lo que es del negocio:

| Servicio | Cuenta | Para qué |
|---|---|---|
| Supabase | mail de Liberate | Base de datos, registro de usuarios, fotos y videos |
| Cloudflare Pages | mail de Liberate | Hosting de la app y el dominio |
| GitHub | tu cuenta (Nicolás) | El código. Después se puede pasar a una organización de Liberate |

Tu cuenta personal de Supabase ya tiene 2 proyectos activos, que es el máximo del plan gratis. Con el mail de Liberate arrancás con una cuenta nueva y limpia.

## 1. Crear el proyecto

1. Entrá a supabase.com con el mail de Liberate.
2. Hacé clic en **New project**:
   - Nombre: `liberate`.
   - Región: **South America (São Paulo)**, que es la más cercana a Argentina.
   - Contraseña de la base: generala y guardala en un lugar seguro.
3. Esperá unos minutos a que termine de crearse.

## 2. Crear las tablas

1. Abrí **SQL Editor → New query**.
2. Pegá todo el archivo `supabase/migrations/20261126000001_esquema_liberate.sql` y hacé clic en **Run**. Crea:
   - las tablas;
   - la seguridad (cada alumno ve solo lo suyo, los profes ven según sus módulos);
   - los buckets de fotos y videos;
   - las funciones de puntos, stock y pedidos.
3. Opcional: corré `supabase/seed.sql`. Carga los productos de la tienda y las clases grabadas del prototipo.

## 3. Hacerte director

1. Registrate en la app con tu mail.
2. En **SQL Editor**, corré esto con tu email:

```sql
update public.profiles set rol = 'director'
where id = (select id from auth.users where email = 'TU-MAIL@ejemplo.com');
```

3. Para los profes, usá el mismo comando cambiando el rol y agregando sus módulos. Por ejemplo, para Juli:

```sql
update public.profiles set rol = 'profe', modulos = '{tienda,ventas,eventos}', rol_label = 'Tienda y ventas'
where id = (select id from auth.users where email = 'juli@ejemplo.com');
```

Los profes que se registran con el **código del equipo** quedan marcados con `solicita_profe = true` para que los apruebes. El código por defecto es `LIBERATE` y se cambia en la tabla `config`.

## 4. Registro e inicio de sesión

1. Andá a **Authentication → Sign In / Providers**:
   - **Email**: dejalo activo, con "Confirm email" prendido.
   - **Google** (opcional): seguí la guía de Supabase para crear las credenciales en Google Cloud.
2. Andá a **Authentication → URL Configuration** y en **Site URL** poné la dirección de la app (la de Cloudflare Pages o tu dominio).
3. Andá a **Authentication → Email Templates** y traducí los mails al español con el tono de Liberate.

## 5. Conectar la app

1. En **Project Settings → API**, copiá la **Project URL** y la **anon public key**.
2. Pegalas en `config.js`, en la raíz del repo.
3. Hacé commit y push. La app deja de estar en "modo demo" y el registro y el inicio de sesión pasan a ser reales.

La `service_role key` **nunca** va en la app ni en el repo.

## 6. Tareas automáticas

Son dos: abrir la lista de cada clase sola y borrar las historias a las 24 horas.

1. En **Database → Extensions**, activá `pg_cron` y `pg_net`.
2. Desplegá la Edge Function que borra las historias, desde la terminal con la CLI de Supabase:
   ```bash
   supabase functions deploy limpiar-historias
   ```
3. En **SQL Editor**, guardá dos secretos:
   ```sql
   select vault.create_secret('https://TU-PROYECTO.supabase.co', 'project_url');
   select vault.create_secret('TU-SERVICE-ROLE-KEY', 'service_role_key');
   ```
4. Corré `supabase/migrations/20261126000002_tareas_programadas.sql`.

## Qué hay en la base

| Área | Tablas |
|---|---|
| Usuarios | `profiles` (alumno / profe / director, sede, turno, plan, módulos) |
| Clases | `clases`, `asistencias` (voy/no voy + presente), `opiniones`, `semana_fija` |
| Puntos | `puntos` (se suman solos), `notas` del profe, vista `ranking_mes` |
| Comunidad | `historias` (vencen a las 24 h), `historia_likes`, `mensajes_grupo`, `entrenos_casa` |
| Cuotas | `cuotas` (el profe marca quién pagó) |
| Tienda | `productos`, `pedidos`, `pedido_items`, `pedido_mensajes` (chat con Juli), `avisos_stock`, vista `ventas_tienda` |
| Eventos | `eventos` (masterclass, yoga…), `inscripciones`, vista `eventos_publicos` |
| Videoteca | `cursos`, `curso_clases`, `compras_cursos` |

Buckets de Storage:

- `avatares`: fotos de perfil, públicas.
- `historias`: solo para usuarios logueados.
- `productos`, `flyers` y `portadas`: públicos.
- `videos`: privado. Una clase se puede ver si es gratis o si el alumno compró el curso.

## Para cuidar el plan gratis

- Comprimí las fotos de las historias en el celular antes de subirlas: alrededor de 1080 px y 100–150 KB.
- Las historias se borran solas a las 24 horas (paso 6).
- Los videos de la videoteca ocupan mucho. Con el plan gratis (1 GB) entran pocas clases. Cuando cargues la videoteca completa, conviene pasar a Pro o alojar los videos en YouTube no listado o en Cloudflare Stream.
