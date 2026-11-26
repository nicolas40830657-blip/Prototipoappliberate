-- =====================================================================
--  LIBERATE · Esquema inicial de la base de datos (Supabase / Postgres)
--  Comunidad de entrenamiento funcional · Plaza y Power Gym
--
--  Cómo usarlo: Supabase → SQL Editor → pegar todo este archivo → Run.
--  (O con la CLI: `supabase db push`.)
--  Es idempotente en lo posible: se puede volver a correr sin romper.
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------
-- 1. SEDES Y CONFIGURACIÓN
-- ---------------------------------------------------------------------
create table if not exists public.sedes (
  id           text primary key,                 -- 'plaza' | 'gym'
  nombre       text not null,
  descripcion  text,
  hora_manana  time not null default '08:00',
  hora_noche   time not null default '19:30',
  activa       boolean not null default true
);

insert into public.sedes (id, nombre, descripcion, hora_manana, hora_noche) values
  ('plaza', 'Plaza',     'Al aire libre · bajo los plátanos', '08:00', '19:30'),
  ('gym',   'Power Gym', 'Adentro · kettlebells y bicis',     '07:30', '20:00')
on conflict (id) do nothing;

create table if not exists public.config (
  clave  text primary key,
  valor  jsonb not null,
  actualizado timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 2. PERFILES (alumnos, profes y director)
--    Un perfil por cada usuario de Supabase Auth.
-- ---------------------------------------------------------------------
create table if not exists public.profiles (
  id              uuid primary key references auth.users (id) on delete cascade,
  rol             text not null default 'alumno' check (rol in ('alumno','profe','director')),
  nombre          text not null default '',
  apellido        text not null default '',
  telefono        text,
  foto_url        text,
  sede_id         text references public.sedes (id),
  turno           text not null default 'n' check (turno in ('m','n')),
  plan_clases     smallint not null default 3 check (plan_clases between 1 and 6),
  -- profes: módulos que el director les habilita (tienda, ventas, pagos, eventos, comunidad, marca, contenido)
  modulos         text[] not null default '{}',
  rol_label       text,                           -- "Tienda y ventas", "Yoga · Momento Yogi"…
  marca           text,                           -- "Momento Yogi"
  solicita_profe  boolean not null default false, -- se registró con el código del equipo
  avisos          jsonb not null default '{"lista":true,"historias":true,"tienda":false}',
  creado          timestamptz not null default now()
);
create index if not exists profiles_rol_idx on public.profiles (rol);

-- Helpers de permisos (security definer para poder usarlos dentro de las políticas RLS)
create or replace function public.mi_rol() returns text
language sql stable security definer set search_path = public as $$
  select rol from public.profiles where id = auth.uid()
$$;

create or replace function public.es_staff() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select rol in ('profe','director') from public.profiles where id = auth.uid()), false)
$$;

create or replace function public.es_director() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select rol = 'director' from public.profiles where id = auth.uid()), false)
$$;

create or replace function public.tiene_modulo(m text) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select rol = 'director' or (rol = 'profe' and m = any (modulos))
                   from public.profiles where id = auth.uid()), false)
$$;

-- Al registrarse alguien en Auth, se crea su perfil con los datos del formulario
create or replace function public.crear_perfil_nuevo() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  m jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
begin
  insert into public.profiles (id, nombre, apellido, telefono, sede_id, turno, plan_clases, solicita_profe)
  values (
    new.id,
    coalesce(m->>'nombre', ''),
    coalesce(m->>'apellido', ''),
    m->>'telefono',
    case when m->>'sede' in (select id from public.sedes) then m->>'sede' else null end,
    case when m->>'turno' in ('m','n') then m->>'turno' else 'n' end,
    coalesce(nullif(m->>'plan','')::smallint, 3),
    upper(coalesce(m->>'codigo_equipo','')) = upper(coalesce((select valor->>0 from public.config where clave = 'codigo_equipo'), '###'))
  )
  on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.crear_perfil_nuevo();

-- Nadie puede cambiarse solo el rol ni los módulos: eso lo hace el director
create or replace function public.proteger_campos_perfil() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not public.es_director() and coalesce(auth.uid() is not null, false) then
    new.rol := old.rol;
    new.modulos := old.modulos;
    new.rol_label := old.rol_label;
    new.marca := old.marca;
  end if;
  return new;
end $$;

drop trigger if exists proteger_perfil on public.profiles;
create trigger proteger_perfil before update on public.profiles
  for each row execute function public.proteger_campos_perfil();

-- ---------------------------------------------------------------------
-- 3. SEMANA FIJA DEL ALUMNO, CLASES Y ASISTENCIA
-- ---------------------------------------------------------------------
create table if not exists public.semana_fija (
  alumno_id  uuid not null references public.profiles (id) on delete cascade,
  dia        smallint not null check (dia between 0 and 6),   -- 0 = lunes
  turno      text not null check (turno in ('m','n')),
  primary key (alumno_id, dia, turno)
);

create table if not exists public.clases (
  id               uuid primary key default gen_random_uuid(),
  fecha            date not null,
  turno            text not null check (turno in ('m','n')),
  hora             time not null,
  sede_id          text not null references public.sedes (id),
  tipo             text not null default 'funcional' check (tipo in ('funcional','yoga')),
  profe_id         uuid references public.profiles (id) on delete set null,
  cupo             smallint not null default 25,
  mensaje          text default 'Hoy entrenamos, ¿quién viene? 💪',
  estado           text not null default 'sin_abrir' check (estado in ('sin_abrir','abierta','terminada','cancelada')),
  clima            text not null default 'normal' check (clima in ('normal','a_confirmar','cancelada')),
  apertura_auto    text not null default 'man' check (apertura_auto in ('man','1h','3h','noche')),
  abre_at          timestamptz,                 -- se calcula solo (ver trigger)
  abierta_at       timestamptz,
  creado           timestamptz not null default now(),
  unique (fecha, turno, sede_id)
);
create index if not exists clases_fecha_idx on public.clases (fecha);
create index if not exists clases_abre_idx on public.clases (abre_at) where estado = 'sin_abrir';

-- Calcula cuándo se abre sola la encuesta (hora de Argentina)
create or replace function public.calcular_apertura() returns trigger
language plpgsql as $$
declare inicio timestamptz := (new.fecha + new.hora) at time zone 'America/Argentina/Buenos_Aires';
begin
  new.abre_at := case new.apertura_auto
    when '1h'    then inicio - interval '1 hour'
    when '3h'    then inicio - interval '3 hours'
    when 'noche' then ((new.fecha - 1) + time '20:00') at time zone 'America/Argentina/Buenos_Aires'
    else null end;
  if new.estado = 'abierta' and new.abierta_at is null then new.abierta_at := now(); end if;
  return new;
end $$;

drop trigger if exists clases_apertura on public.clases;
create trigger clases_apertura before insert or update of fecha, hora, apertura_auto, estado on public.clases
  for each row execute function public.calcular_apertura();

-- La llama el cron cada 5 minutos: abre las encuestas que ya tienen que estar abiertas
create or replace function public.abrir_encuestas_programadas() returns integer
language sql security definer set search_path = public as $$
  with x as (
    update public.clases set estado = 'abierta', abierta_at = now()
    where estado = 'sin_abrir' and abre_at is not null and abre_at <= now()
    returning 1)
  select count(*)::int from x
$$;

create table if not exists public.asistencias (
  clase_id     uuid not null references public.clases (id) on delete cascade,
  alumno_id    uuid not null references public.profiles (id) on delete cascade,
  respuesta    text check (respuesta in ('voy','no_voy')),
  respondio_at timestamptz,
  presente     boolean not null default false,
  marcado_por  uuid references public.profiles (id),
  primary key (clase_id, alumno_id)
);
create index if not exists asistencias_alumno_idx on public.asistencias (alumno_id);

create table if not exists public.opiniones (
  clase_id    uuid not null references public.clases (id) on delete cascade,
  alumno_id   uuid not null references public.profiles (id) on delete cascade,
  cara        smallint not null check (cara between 0 and 4),
  dificultad  smallint not null check (dificultad between 1 and 5),
  comentario  text,
  creado      timestamptz not null default now(),
  primary key (clase_id, alumno_id)
);

-- El alumno responde "voy / no voy" solo si la encuesta está abierta
create or replace function public.responder_clase(p_clase uuid, p_respuesta text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if p_respuesta not in ('voy','no_voy') then raise exception 'Respuesta inválida'; end if;
  if not exists (select 1 from public.clases where id = p_clase and estado = 'abierta') then
    raise exception 'La lista todavía no está abierta';
  end if;
  insert into public.asistencias (clase_id, alumno_id, respuesta, respondio_at)
  values (p_clase, auth.uid(), p_respuesta, now())
  on conflict (clase_id, alumno_id) do update set respuesta = excluded.respuesta, respondio_at = now();
end $$;

-- ---------------------------------------------------------------------
-- 4. PUNTOS, RANKING Y NOTAS DEL PROFE
-- ---------------------------------------------------------------------
create table if not exists public.puntos (
  id         bigint generated always as identity primary key,
  alumno_id  uuid not null references public.profiles (id) on delete cascade,
  motivo     text not null check (motivo in ('asistencia','historia','casa','opinion','nota','evento','ajuste')),
  puntos     integer not null,
  ref        text,                        -- id de lo que los generó (clase, historia, nota…)
  creado     timestamptz not null default now(),
  unique (alumno_id, motivo, ref)         -- evita sumar dos veces lo mismo
);
create index if not exists puntos_alumno_fecha_idx on public.puntos (alumno_id, creado);

-- Valores de cada acción (editables desde config)
insert into public.config (clave, valor) values
  ('puntos', '{"asistencia":10,"historia":4,"casa":3,"opinion":2}'),
  ('codigo_equipo', '["LIBERATE"]'),
  ('ganancia_general', '100')
on conflict (clave) do nothing;

create or replace function public.valor_puntos(m text) returns integer
language sql stable as $$
  select coalesce((select (valor->>m)::int from public.config where clave = 'puntos'), 0)
$$;

-- +10 al quedar presente (y se descuenta si el profe lo desmarca)
create or replace function public.puntos_por_asistencia() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.presente and not coalesce(old.presente, false) then
    insert into public.puntos (alumno_id, motivo, puntos, ref)
    values (new.alumno_id, 'asistencia', public.valor_puntos('asistencia'), new.clase_id::text)
    on conflict do nothing;
  elsif not new.presente and coalesce(old.presente, false) then
    delete from public.puntos where alumno_id = new.alumno_id and motivo = 'asistencia' and ref = new.clase_id::text;
  end if;
  return new;
end $$;

drop trigger if exists asistencia_puntos on public.asistencias;
create trigger asistencia_puntos after insert or update of presente on public.asistencias
  for each row execute function public.puntos_por_asistencia();

-- +2 por opinar
create or replace function public.puntos_por_opinion() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.puntos (alumno_id, motivo, puntos, ref)
  values (new.alumno_id, 'opinion', public.valor_puntos('opinion'), new.clase_id::text)
  on conflict do nothing;
  return new;
end $$;

drop trigger if exists opinion_puntos on public.opiniones;
create trigger opinion_puntos after insert on public.opiniones
  for each row execute function public.puntos_por_opinion();

create table if not exists public.notas (
  id         uuid primary key default gen_random_uuid(),
  alumno_id  uuid not null references public.profiles (id) on delete cascade,
  profe_id   uuid not null references public.profiles (id) on delete cascade,
  texto      text not null,
  puntos     smallint not null default 0 check (puntos between 0 and 20),
  publica    boolean not null default false,   -- el alumno decide si la comparte
  creado     timestamptz not null default now()
);
create index if not exists notas_alumno_idx on public.notas (alumno_id);

create or replace function public.puntos_por_nota() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.puntos > 0 then
    insert into public.puntos (alumno_id, motivo, puntos, ref)
    values (new.alumno_id, 'nota', new.puntos, new.id::text) on conflict do nothing;
  end if;
  return new;
end $$;

drop trigger if exists nota_puntos on public.notas;
create trigger nota_puntos after insert on public.notas
  for each row execute function public.puntos_por_nota();

-- El alumno solo puede cambiar "publica" de sus notas
create or replace function public.compartir_nota(p_nota uuid, p_publica boolean) returns void
language sql security definer set search_path = public as $$
  update public.notas set publica = p_publica where id = p_nota and alumno_id = auth.uid()
$$;

-- Ranking del mes en curso
create or replace view public.ranking_mes with (security_invoker = true) as
select p.id as alumno_id, p.nombre, p.apellido, p.foto_url, p.sede_id,
       coalesce(sum(pt.puntos), 0)::int as puntos,
       rank() over (order by coalesce(sum(pt.puntos), 0) desc) as puesto
from public.profiles p
left join public.puntos pt
  on pt.alumno_id = p.id
 and pt.creado >= date_trunc('month', now() at time zone 'America/Argentina/Buenos_Aires') at time zone 'America/Argentina/Buenos_Aires'
where p.rol = 'alumno'
group by p.id;

-- ---------------------------------------------------------------------
-- 5. HISTORIAS (se borran a las 24 h) Y CHAT DEL GRUPO
-- ---------------------------------------------------------------------
create table if not exists public.historias (
  id         uuid primary key default gen_random_uuid(),
  alumno_id  uuid not null references public.profiles (id) on delete cascade,
  foto_path  text not null,                 -- ruta en el bucket "historias"
  frase      text,                          -- la burbuja: "Aguante Liberate 💚"
  lugar      text,
  creado     timestamptz not null default now(),
  expira_at  timestamptz not null default now() + interval '24 hours'
);
create index if not exists historias_expira_idx on public.historias (expira_at);
create index if not exists historias_alumno_idx on public.historias (alumno_id, creado desc);

-- +4 la primera historia de cada día
create or replace function public.puntos_por_historia() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.puntos (alumno_id, motivo, puntos, ref)
  values (new.alumno_id, 'historia', public.valor_puntos('historia'),
          to_char(new.creado at time zone 'America/Argentina/Buenos_Aires', 'YYYY-MM-DD'))
  on conflict do nothing;
  return new;
end $$;

drop trigger if exists historia_puntos on public.historias;
create trigger historia_puntos after insert on public.historias
  for each row execute function public.puntos_por_historia();

create table if not exists public.historia_likes (
  historia_id uuid not null references public.historias (id) on delete cascade,
  user_id     uuid not null references public.profiles (id) on delete cascade,
  creado      timestamptz not null default now(),
  primary key (historia_id, user_id)
);

create table if not exists public.mensajes_grupo (
  id        bigint generated always as identity primary key,
  autor_id  uuid not null references public.profiles (id) on delete cascade,
  texto     text not null check (char_length(texto) between 1 and 1000),
  creado    timestamptz not null default now()
);
create index if not exists mensajes_grupo_creado_idx on public.mensajes_grupo (creado desc);

-- "Entrenar en casa": registro de entrenamientos hechos (+3, uno por día)
create table if not exists public.entrenos_casa (
  id         bigint generated always as identity primary key,
  alumno_id  uuid not null references public.profiles (id) on delete cascade,
  rutina     text not null,
  creado     timestamptz not null default now()
);

create or replace function public.puntos_por_casa() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.puntos (alumno_id, motivo, puntos, ref)
  values (new.alumno_id, 'casa', public.valor_puntos('casa'),
          to_char(new.creado at time zone 'America/Argentina/Buenos_Aires', 'YYYY-MM-DD'))
  on conflict do nothing;
  return new;
end $$;

drop trigger if exists casa_puntos on public.entrenos_casa;
create trigger casa_puntos after insert on public.entrenos_casa
  for each row execute function public.puntos_por_casa();

-- ---------------------------------------------------------------------
-- 6. CUOTAS (el pago se hace por fuera; el profe lo marca)
-- ---------------------------------------------------------------------
create table if not exists public.cuotas (
  id           uuid primary key default gen_random_uuid(),
  alumno_id    uuid not null references public.profiles (id) on delete cascade,
  mes          date not null,                     -- primer día del mes
  estado       text not null default 'pendiente' check (estado in ('pendiente','pagado')),
  monto        integer,
  marcado_por  uuid references public.profiles (id),
  marcado_at   timestamptz,
  unique (alumno_id, mes)
);

-- ---------------------------------------------------------------------
-- 7. TIENDA: productos, pedidos con chat, ventas en mano
-- ---------------------------------------------------------------------
create table if not exists public.productos (
  id            uuid primary key default gen_random_uuid(),
  nombre        text not null,
  categoria     text not null default 'Ropa' check (categoria in ('Ropa','Accesorios','Equipamiento','Momento Yogi')),
  marca         text not null default 'liberate' check (marca in ('liberate','momento_yogi')),
  descripcion   text,
  costo         integer not null default 0,        -- en pesos
  precio        integer not null default 0,        -- precio de lista
  promo_pct     smallint not null default 0 check (promo_pct between 0 and 90),
  tiene_talles  boolean not null default false,
  stock         integer not null default 0,        -- si no tiene talles
  stock_talles  jsonb not null default '{}',       -- {"S":2,"M":4,"L":4,"XL":2}
  es_servicio   boolean not null default false,    -- p. ej. pack de clases de yoga
  fotos         text[] not null default '{}',      -- [producto, puesto/IA, detalle]
  visible       boolean not null default true,
  orden         integer not null default 0,
  creado        timestamptz not null default now()
);

create or replace view public.productos_publicos with (security_invoker = true) as
select p.*,
       case when promo_pct > 0 then (round(precio * (1 - promo_pct / 100.0) / 100.0) * 100)::int else precio end as precio_final,
       case when costo > 0 then round((precio - costo) * 100.0 / costo)::int else null end as ganancia_pct,
       case when tiene_talles then (select coalesce(sum(value::int), 0) from jsonb_each_text(stock_talles))::int else stock end as stock_total
from public.productos p;

create table if not exists public.avisos_stock (
  producto_id  uuid not null references public.productos (id) on delete cascade,
  alumno_id    uuid not null references public.profiles (id) on delete cascade,
  creado       timestamptz not null default now(),
  primary key (producto_id, alumno_id)
);

create table if not exists public.pedidos (
  id              bigint generated always as identity (start with 1040) primary key,
  alumno_id       uuid references public.profiles (id) on delete set null,
  nombre_cliente  text,                               -- para ventas en mano a "otra persona"
  origen          text not null default 'app' check (origen in ('app','mano')),
  medio_pago      text not null check (medio_pago in ('mp','tr','ef','cu')),
  estado          text not null default 'nuevo' check (estado in ('nuevo','coordinado','entregado')),
  cobrado         boolean not null default false,
  total           integer not null default 0,
  cerrado_at      timestamptz,                        -- entregado + cobrado
  creado          timestamptz not null default now()
);
create index if not exists pedidos_alumno_idx on public.pedidos (alumno_id);

create table if not exists public.pedido_items (
  id           bigint generated always as identity primary key,
  pedido_id    bigint not null references public.pedidos (id) on delete cascade,
  producto_id  uuid not null references public.productos (id),
  talle        text,
  cantidad     smallint not null check (cantidad > 0),
  precio_unit  integer not null,
  costo_unit   integer not null default 0
);

create table if not exists public.pedido_mensajes (
  id         bigint generated always as identity primary key,
  pedido_id  bigint not null references public.pedidos (id) on delete cascade,
  autor_id   uuid references public.profiles (id) on delete set null,
  texto      text not null,
  automatico boolean not null default false,
  sistema    boolean not null default false,
  leido      boolean not null default false,
  creado     timestamptz not null default now()
);
create index if not exists pedido_mensajes_pedido_idx on public.pedido_mensajes (pedido_id, creado);

-- Al cargar un ítem: fija precio/costo y descuenta stock
create or replace function public.item_precio_y_stock() returns trigger
language plpgsql security definer set search_path = public as $$
declare pr public.productos;
begin
  select * into pr from public.productos where id = new.producto_id for update;
  new.precio_unit := case when pr.promo_pct > 0 then (round(pr.precio * (1 - pr.promo_pct / 100.0) / 100.0) * 100)::int else pr.precio end;
  new.costo_unit := pr.costo;
  if pr.tiene_talles then
    if new.talle is null or coalesce((pr.stock_talles->>new.talle)::int, 0) < new.cantidad then
      raise exception 'Sin stock de % talle %', pr.nombre, coalesce(new.talle, '?');
    end if;
    update public.productos
       set stock_talles = jsonb_set(stock_talles, array[new.talle], to_jsonb((stock_talles->>new.talle)::int - new.cantidad))
     where id = pr.id;
  elsif not pr.es_servicio then
    if pr.stock < new.cantidad then raise exception 'Sin stock de %', pr.nombre; end if;
    update public.productos set stock = stock - new.cantidad where id = pr.id;
  end if;
  return new;
end $$;

drop trigger if exists item_stock on public.pedido_items;
create trigger item_stock before insert on public.pedido_items
  for each row execute function public.item_precio_y_stock();

create or replace function public.recalcular_total() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  update public.pedidos set total = (select coalesce(sum(precio_unit * cantidad), 0) from public.pedido_items where pedido_id = new.pedido_id)
   where id = new.pedido_id;
  return null;
end $$;

drop trigger if exists item_total on public.pedido_items;
create trigger item_total after insert on public.pedido_items
  for each row execute function public.recalcular_total();

-- Pedido cerrado (entregado y cobrado) → fecha de cierre + mensaje de sistema
create or replace function public.cerrar_pedido() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.estado = 'entregado' and new.cobrado and new.cerrado_at is null then
    new.cerrado_at := now();
  end if;
  return new;
end $$;

drop trigger if exists pedido_cierre on public.pedidos;
create trigger pedido_cierre before insert or update on public.pedidos
  for each row execute function public.cerrar_pedido();

-- El alumno confirma su carrito: crea el pedido, los ítems y el mensaje automático de Juli
create or replace function public.confirmar_pedido(p_items jsonb, p_medio text) returns bigint
language plpgsql security definer set search_path = public as $$
declare
  v_id bigint; it jsonb; v_nombre text; v_txt text := '';
begin
  if auth.uid() is null then raise exception 'Tenés que iniciar sesión'; end if;
  insert into public.pedidos (alumno_id, origen, medio_pago, cobrado)
  values (auth.uid(), 'app', p_medio, p_medio in ('mp','cu')) returning id into v_id;
  for it in select * from jsonb_array_elements(p_items) loop
    insert into public.pedido_items (pedido_id, producto_id, talle, cantidad)
    values (v_id, (it->>'producto_id')::uuid, it->>'talle', coalesce((it->>'cantidad')::smallint, 1));
  end loop;
  select string_agg(case when i.cantidad > 1 then i.cantidad || '× ' else '' end || p.nombre || coalesce(' (' || i.talle || ')', ''), ', ')
    into v_txt from public.pedido_items i join public.productos p on p.id = i.producto_id where i.pedido_id = v_id;
  select nombre into v_nombre from public.profiles where id = auth.uid();
  insert into public.pedido_mensajes (pedido_id, autor_id, texto, automatico)
  values (v_id, (select id from public.profiles where rol <> 'alumno' and 'tienda' = any (modulos) order by creado limit 1),
          '¡Hola ' || coalesce(nullif(v_nombre, ''), '') || '! Ya me llegó tu pedido de ' || coalesce(v_txt, 'tu compra') ||
          ' 🙌 ¿Te lo llevo a la próxima clase? Cualquier consulta, escribime acá.', true);
  return v_id;
end $$;

-- Ventas de la tienda (para números y métricas): solo pedidos cerrados
create or replace view public.ventas_tienda with (security_invoker = true) as
select pe.id as pedido_id, pe.cerrado_at, pe.origen, pe.medio_pago,
       i.producto_id, pr.nombre as producto, i.cantidad, i.precio_unit, i.costo_unit,
       i.cantidad * i.precio_unit as facturado,
       i.cantidad * (i.precio_unit - i.costo_unit) as ganancia
from public.pedidos pe
join public.pedido_items i on i.pedido_id = pe.id
join public.productos pr on pr.id = i.producto_id
where pe.cerrado_at is not null;

-- ---------------------------------------------------------------------
-- 8. EVENTOS Y MASTERCLASS
-- ---------------------------------------------------------------------
create table if not exists public.eventos (
  id           uuid primary key default gen_random_uuid(),
  tipo         text not null default 'masterclass' check (tipo in ('masterclass','yoga','evento')),
  nombre       text not null,
  bajada       text,
  fecha        date not null,
  hora         time not null,
  lugar        text not null default 'Plaza',
  profe_id     uuid references public.profiles (id) on delete set null,
  precio       integer not null default 0,
  cupo         integer not null default 40,
  flyer_path   text,                              -- bucket "flyers"
  aviso_dias   smallint not null default 7,        -- cuántos días antes aparece el aviso en Hoy
  descripcion  text,
  estado       text not null default 'pendiente' check (estado in ('pendiente','publicado','cancelado')),
  creado       timestamptz not null default now()
);
create index if not exists eventos_fecha_idx on public.eventos (fecha);

-- Si lo crea un profe queda pendiente; si lo crea el director, publicado
create or replace function public.estado_evento_nuevo() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if public.es_director() then
    new.estado := coalesce(nullif(new.estado, 'pendiente'), 'publicado');
  else
    new.estado := 'pendiente';
  end if;
  if new.profe_id is null then new.profe_id := auth.uid(); end if;
  return new;
end $$;

drop trigger if exists evento_estado on public.eventos;
create trigger evento_estado before insert on public.eventos
  for each row execute function public.estado_evento_nuevo();

create table if not exists public.inscripciones (
  evento_id   uuid not null references public.eventos (id) on delete cascade,
  alumno_id   uuid not null references public.profiles (id) on delete cascade,
  medio_pago  text not null default 'ef' check (medio_pago in ('ef','tr','mp','gratis')),
  cobrado     boolean not null default false,
  creado      timestamptz not null default now(),
  primary key (evento_id, alumno_id)
);

-- Inscribirse controlando el cupo
create or replace function public.inscribirme(p_evento uuid, p_medio text) returns void
language plpgsql security definer set search_path = public as $$
declare e public.eventos;
begin
  select * into e from public.eventos where id = p_evento and estado = 'publicado' for update;
  if e.id is null then raise exception 'Evento no disponible'; end if;
  if (select count(*) from public.inscripciones where evento_id = p_evento) >= e.cupo then
    raise exception 'No quedan lugares';
  end if;
  insert into public.inscripciones (evento_id, alumno_id, medio_pago, cobrado)
  values (p_evento, auth.uid(), case when e.precio = 0 then 'gratis' else p_medio end, e.precio = 0 or p_medio = 'mp')
  on conflict do nothing;
end $$;

create or replace view public.eventos_publicos with (security_invoker = true) as
select e.*, (select count(*) from public.inscripciones i where i.evento_id = e.id)::int as anotados,
       (e.fecha - (now() at time zone 'America/Argentina/Buenos_Aires')::date) as faltan_dias
from public.eventos e;

-- ---------------------------------------------------------------------
-- 9. CLASES GRABADAS (la videoteca)
-- ---------------------------------------------------------------------
create table if not exists public.cursos (
  id            uuid primary key default gen_random_uuid(),
  nombre        text not null,
  bajada        text,
  marca         text not null default 'liberate' check (marca in ('liberate','momento_yogi')),
  profe_id      uuid references public.profiles (id) on delete set null,
  precio        integer not null default 0,
  nivel         text,
  portada_path  text,                              -- bucket "portadas"
  publicado     boolean not null default false,
  orden         integer not null default 0,
  creado        timestamptz not null default now()
);

create table if not exists public.curso_clases (
  id          uuid primary key default gen_random_uuid(),
  curso_id    uuid not null references public.cursos (id) on delete cascade,
  orden       smallint not null default 1,
  titulo      text not null,
  minutos     smallint not null default 15,
  video_path  text,                                -- bucket privado "videos": <curso_id>/<archivo>
  gratis      boolean not null default false,      -- la primera siempre gratis
  creado      timestamptz not null default now()
);
create index if not exists curso_clases_curso_idx on public.curso_clases (curso_id, orden);

create table if not exists public.compras_cursos (
  curso_id    uuid not null references public.cursos (id) on delete cascade,
  alumno_id   uuid not null references public.profiles (id) on delete cascade,
  medio_pago  text not null default 'mp' check (medio_pago in ('mp','tr','ef')),
  confirmado  boolean not null default false,      -- MP: true al acreditarse; efectivo/transferencia: lo confirma el profe
  creado      timestamptz not null default now(),
  primary key (curso_id, alumno_id)
);

create or replace function public.tiene_curso(p_curso uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.compras_cursos where curso_id = p_curso and alumno_id = auth.uid() and confirmado)
$$;

-- ---------------------------------------------------------------------
-- 10. SEGURIDAD: ROW LEVEL SECURITY
-- ---------------------------------------------------------------------
alter table public.sedes            enable row level security;
alter table public.config           enable row level security;
alter table public.profiles         enable row level security;
alter table public.semana_fija      enable row level security;
alter table public.clases           enable row level security;
alter table public.asistencias      enable row level security;
alter table public.opiniones        enable row level security;
alter table public.puntos           enable row level security;
alter table public.notas            enable row level security;
alter table public.historias        enable row level security;
alter table public.historia_likes   enable row level security;
alter table public.mensajes_grupo   enable row level security;
alter table public.entrenos_casa    enable row level security;
alter table public.cuotas           enable row level security;
alter table public.productos        enable row level security;
alter table public.avisos_stock     enable row level security;
alter table public.pedidos          enable row level security;
alter table public.pedido_items     enable row level security;
alter table public.pedido_mensajes  enable row level security;
alter table public.eventos          enable row level security;
alter table public.inscripciones    enable row level security;
alter table public.cursos           enable row level security;
alter table public.curso_clases     enable row level security;
alter table public.compras_cursos   enable row level security;

-- Borra políticas anteriores (para poder volver a correr el archivo)
do $$ declare r record; begin
  for r in select policyname, tablename from pg_policies where schemaname = 'public' loop
    execute format('drop policy if exists %I on public.%I', r.policyname, r.tablename);
  end loop;
end $$;

-- Sedes y config: todos leen; el director edita
create policy "sedes: leer" on public.sedes for select using (true);
create policy "sedes: director" on public.sedes for all to authenticated using (public.es_director()) with check (public.es_director());
create policy "config: leer" on public.config for select to authenticated using (clave <> 'codigo_equipo' or public.es_staff());
create policy "config: director" on public.config for all to authenticated using (public.es_director()) with check (public.es_director());

-- Perfiles: la comunidad se ve entre sí; cada uno edita el suyo; el director edita todos
create policy "perfiles: leer" on public.profiles for select to authenticated using (true);
create policy "perfiles: editar el mío" on public.profiles for update to authenticated using (id = auth.uid()) with check (id = auth.uid());
create policy "perfiles: director" on public.profiles for update to authenticated using (public.es_director()) with check (true);

-- Semana fija
create policy "semana: mía" on public.semana_fija for all to authenticated using (alumno_id = auth.uid()) with check (alumno_id = auth.uid());
create policy "semana: staff lee" on public.semana_fija for select to authenticated using (public.es_staff());

-- Clases: todos leen; staff gestiona
create policy "clases: leer" on public.clases for select to authenticated using (true);
create policy "clases: staff" on public.clases for all to authenticated using (public.es_staff()) with check (public.es_staff());

-- Asistencias: todos ven quién va (la "multitud" de Hoy); responder se hace con responder_clase(); el staff marca presentes
create policy "asistencias: leer" on public.asistencias for select to authenticated using (true);
create policy "asistencias: staff" on public.asistencias for all to authenticated using (public.es_staff()) with check (public.es_staff());

-- Opiniones: el alumno carga la suya (si estuvo presente); el staff lee todas
create policy "opiniones: mía" on public.opiniones for insert to authenticated
  with check (alumno_id = auth.uid() and exists (select 1 from public.asistencias a where a.clase_id = opiniones.clase_id and a.alumno_id = auth.uid() and a.presente));
create policy "opiniones: leer" on public.opiniones for select to authenticated using (alumno_id = auth.uid() or public.es_staff());

-- Puntos: todos leen (ranking); solo staff carga ajustes a mano (el resto lo hacen los triggers)
create policy "puntos: leer" on public.puntos for select to authenticated using (true);
create policy "puntos: staff" on public.puntos for all to authenticated using (public.es_staff()) with check (public.es_staff());

-- Notas del profe: privadas (alumno + staff) salvo que el alumno las comparta
create policy "notas: leer" on public.notas for select to authenticated using (alumno_id = auth.uid() or publica or public.es_staff());
create policy "notas: staff escribe" on public.notas for insert to authenticated with check (public.es_staff() and profe_id = auth.uid());
create policy "notas: staff edita" on public.notas for update to authenticated using (public.es_staff()) with check (public.es_staff());
create policy "notas: staff borra" on public.notas for delete to authenticated using (public.es_staff());

-- Historias: se ven las que no vencieron; cada uno sube y borra las suyas; el staff puede ocultar
create policy "historias: leer" on public.historias for select to authenticated using (expira_at > now() or alumno_id = auth.uid());
create policy "historias: subir" on public.historias for insert to authenticated with check (alumno_id = auth.uid());
create policy "historias: borrar" on public.historias for delete to authenticated using (alumno_id = auth.uid() or public.es_staff());
create policy "likes: leer" on public.historia_likes for select to authenticated using (true);
create policy "likes: míos" on public.historia_likes for insert to authenticated with check (user_id = auth.uid());
create policy "likes: sacar" on public.historia_likes for delete to authenticated using (user_id = auth.uid());

-- Chat del grupo
create policy "grupo: leer" on public.mensajes_grupo for select to authenticated using (true);
create policy "grupo: escribir" on public.mensajes_grupo for insert to authenticated with check (autor_id = auth.uid());
create policy "grupo: borrar" on public.mensajes_grupo for delete to authenticated using (autor_id = auth.uid() or public.es_staff());

-- Entrenar en casa
create policy "casa: mío" on public.entrenos_casa for all to authenticated using (alumno_id = auth.uid()) with check (alumno_id = auth.uid());
create policy "casa: staff lee" on public.entrenos_casa for select to authenticated using (public.es_staff());

-- Cuotas: el alumno ve las suyas; profes con "pagos" (o el director) las marcan
create policy "cuotas: mías" on public.cuotas for select to authenticated using (alumno_id = auth.uid() or public.es_staff());
create policy "cuotas: pagos" on public.cuotas for all to authenticated using (public.tiene_modulo('pagos')) with check (public.tiene_modulo('pagos'));

-- Productos: se ven los visibles; tienda gestiona
create policy "productos: leer" on public.productos for select using (visible or public.tiene_modulo('tienda'));
create policy "productos: tienda" on public.productos for all to authenticated using (public.tiene_modulo('tienda') or (marca = 'momento_yogi' and public.tiene_modulo('marca'))) with check (public.tiene_modulo('tienda') or (marca = 'momento_yogi' and public.tiene_modulo('marca')));
create policy "avisos stock: míos" on public.avisos_stock for all to authenticated using (alumno_id = auth.uid()) with check (alumno_id = auth.uid());
create policy "avisos stock: tienda lee" on public.avisos_stock for select to authenticated using (public.tiene_modulo('tienda'));

-- Pedidos: el alumno ve los suyos; tienda ve y gestiona todos (los alumnos crean con confirmar_pedido())
create policy "pedidos: leer" on public.pedidos for select to authenticated using (alumno_id = auth.uid() or public.tiene_modulo('tienda'));
create policy "pedidos: tienda" on public.pedidos for all to authenticated using (public.tiene_modulo('tienda')) with check (public.tiene_modulo('tienda'));
create policy "items: leer" on public.pedido_items for select to authenticated
  using (exists (select 1 from public.pedidos p where p.id = pedido_id and (p.alumno_id = auth.uid() or public.tiene_modulo('tienda'))));
create policy "items: tienda" on public.pedido_items for all to authenticated using (public.tiene_modulo('tienda')) with check (public.tiene_modulo('tienda'));
create policy "chat pedido: leer" on public.pedido_mensajes for select to authenticated
  using (exists (select 1 from public.pedidos p where p.id = pedido_id and (p.alumno_id = auth.uid() or public.tiene_modulo('tienda'))));
create policy "chat pedido: escribir" on public.pedido_mensajes for insert to authenticated
  with check (autor_id = auth.uid() and not automatico and not sistema
              and exists (select 1 from public.pedidos p where p.id = pedido_id and p.cerrado_at is null and (p.alumno_id = auth.uid() or public.tiene_modulo('tienda'))));
create policy "chat pedido: marcar leído" on public.pedido_mensajes for update to authenticated
  using (exists (select 1 from public.pedidos p where p.id = pedido_id and (p.alumno_id = auth.uid() or public.tiene_modulo('tienda'))));

-- Eventos: los alumnos ven los publicados; profes con "eventos" crean; el director aprueba
create policy "eventos: leer" on public.eventos for select to authenticated using (estado = 'publicado' or public.tiene_modulo('eventos'));
create policy "eventos: crear" on public.eventos for insert to authenticated with check (public.tiene_modulo('eventos'));
create policy "eventos: editar" on public.eventos for update to authenticated using (public.es_director() or (public.tiene_modulo('eventos') and profe_id = auth.uid())) with check (true);
create policy "eventos: borrar" on public.eventos for delete to authenticated using (public.es_director());
create policy "inscripciones: leer" on public.inscripciones for select to authenticated using (alumno_id = auth.uid() or public.tiene_modulo('eventos'));
create policy "inscripciones: cancelar la mía" on public.inscripciones for delete to authenticated using (alumno_id = auth.uid());
create policy "inscripciones: gestionar" on public.inscripciones for all to authenticated using (public.tiene_modulo('eventos')) with check (public.tiene_modulo('eventos'));

-- Videoteca
create policy "cursos: leer" on public.cursos for select to authenticated using (publicado or public.tiene_modulo('contenido'));
create policy "cursos: gestionar" on public.cursos for all to authenticated using (public.tiene_modulo('contenido')) with check (public.tiene_modulo('contenido'));
create policy "clases curso: leer" on public.curso_clases for select to authenticated using (true);
create policy "clases curso: gestionar" on public.curso_clases for all to authenticated using (public.tiene_modulo('contenido')) with check (public.tiene_modulo('contenido'));
create policy "compras: mías" on public.compras_cursos for select to authenticated using (alumno_id = auth.uid() or public.tiene_modulo('contenido'));
create policy "compras: pedir" on public.compras_cursos for insert to authenticated with check (alumno_id = auth.uid() and not confirmado);
create policy "compras: confirmar" on public.compras_cursos for update to authenticated using (public.tiene_modulo('contenido')) with check (public.tiene_modulo('contenido'));

-- Permisos de ejecución de las funciones que llama la app
grant execute on function public.responder_clase(uuid, text) to authenticated;
grant execute on function public.compartir_nota(uuid, boolean) to authenticated;
grant execute on function public.confirmar_pedido(jsonb, text) to authenticated;
grant execute on function public.inscribirme(uuid, text) to authenticated;
revoke execute on function public.abrir_encuestas_programadas() from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 11. STORAGE (fotos y videos)
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types) values
  ('avatares',  'avatares',  true,  2097152,   array['image/jpeg','image/png','image/webp','image/avif']),
  ('historias', 'historias', false, 1572864,   array['image/jpeg','image/webp','image/avif']),
  ('productos', 'productos', true,  3145728,   array['image/jpeg','image/png','image/webp','image/avif']),
  ('flyers',    'flyers',    true,  3145728,   array['image/jpeg','image/png','image/webp','image/avif']),
  ('portadas',  'portadas',  true,  3145728,   array['image/jpeg','image/png','image/webp','image/avif']),
  ('videos',    'videos',    false, 524288000, array['video/mp4','video/webm','video/quicktime'])
on conflict (id) do update set public = excluded.public, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

do $$ declare r record; begin
  for r in select policyname from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname like 'lib:%' loop
    execute format('drop policy if exists %I on storage.objects', r.policyname);
  end loop;
end $$;

-- Avatares: cada uno sube el suyo en la carpeta <su id>/
create policy "lib: avatares leer" on storage.objects for select using (bucket_id = 'avatares');
create policy "lib: avatares subir" on storage.objects for insert to authenticated
  with check (bucket_id = 'avatares' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "lib: avatares cambiar" on storage.objects for update to authenticated
  using (bucket_id = 'avatares' and (storage.foldername(name))[1] = auth.uid()::text);

-- Historias: solo usuarios logueados las ven; cada uno sube en <su id>/
create policy "lib: historias leer" on storage.objects for select to authenticated using (bucket_id = 'historias');
create policy "lib: historias subir" on storage.objects for insert to authenticated
  with check (bucket_id = 'historias' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "lib: historias borrar" on storage.objects for delete to authenticated
  using (bucket_id = 'historias' and ((storage.foldername(name))[1] = auth.uid()::text or public.es_staff()));

-- Productos, flyers y portadas: públicos para leer; los suben los profes con el módulo
create policy "lib: catálogo leer" on storage.objects for select using (bucket_id in ('productos','flyers','portadas'));
create policy "lib: productos subir" on storage.objects for insert to authenticated
  with check (bucket_id = 'productos' and (public.tiene_modulo('tienda') or public.tiene_modulo('marca')));
create policy "lib: flyers subir" on storage.objects for insert to authenticated
  with check (bucket_id = 'flyers' and public.tiene_modulo('eventos'));
create policy "lib: portadas subir" on storage.objects for insert to authenticated
  with check (bucket_id = 'portadas' and public.tiene_modulo('contenido'));
create policy "lib: catálogo cambiar" on storage.objects for update to authenticated
  using (bucket_id in ('productos','flyers','portadas') and public.es_staff());
create policy "lib: catálogo borrar" on storage.objects for delete to authenticated
  using (bucket_id in ('productos','flyers','portadas') and public.es_staff());

-- Videos: privados. Se ven si la clase es gratis o si el alumno compró el curso. Ruta: <curso_id>/<archivo>
create policy "lib: videos ver" on storage.objects for select to authenticated
  using (bucket_id = 'videos' and (
    public.tiene_modulo('contenido')
    or exists (select 1 from public.curso_clases c
               where c.video_path = storage.objects.name
                 and (c.gratis or public.tiene_curso(c.curso_id)))));
create policy "lib: videos subir" on storage.objects for insert to authenticated
  with check (bucket_id = 'videos' and public.tiene_modulo('contenido'));
create policy "lib: videos borrar" on storage.objects for delete to authenticated
  using (bucket_id = 'videos' and public.tiene_modulo('contenido'));

-- ---------------------------------------------------------------------
-- 12. TIEMPO REAL (chat del grupo, chats de pedidos, lista de Hoy)
-- ---------------------------------------------------------------------
do $$ begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    begin alter publication supabase_realtime add table public.mensajes_grupo;  exception when duplicate_object then null; end;
    begin alter publication supabase_realtime add table public.pedido_mensajes; exception when duplicate_object then null; end;
    begin alter publication supabase_realtime add table public.asistencias;     exception when duplicate_object then null; end;
    begin alter publication supabase_realtime add table public.clases;          exception when duplicate_object then null; end;
  end if;
end $$;
