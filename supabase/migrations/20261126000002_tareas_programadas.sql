-- =====================================================================
--  LIBERATE · Tareas automáticas (Supabase Cron)
--  1) Abre las encuestas programadas (cada 5 minutos)
--  2) Borra las historias vencidas (cada hora) llamando a la Edge Function
--     "limpiar-historias", que borra la foto del Storage y la fila.
--
--  Antes de correr este archivo:
--   · Database → Extensions: activar "pg_cron" y "pg_net".
--   · Desplegar la Edge Function supabase/functions/limpiar-historias.
--   · Guardar en el Vault la URL del proyecto y la service role key:
--       select vault.create_secret('https://TU-PROYECTO.supabase.co', 'project_url');
--       select vault.create_secret('TU-SERVICE-ROLE-KEY', 'service_role_key');
-- =====================================================================

create extension if not exists pg_cron;
create extension if not exists pg_net;

-- 1) Apertura automática de la lista de cada clase
select cron.unschedule(jobid) from cron.job where jobname = 'liberate-abrir-encuestas';
select cron.schedule('liberate-abrir-encuestas', '*/5 * * * *', $$ select public.abrir_encuestas_programadas(); $$);

-- 2) Limpieza de historias vencidas (más de 24 h)
select cron.unschedule(jobid) from cron.job where jobname = 'liberate-limpiar-historias';
select cron.schedule('liberate-limpiar-historias', '7 * * * *', $$
  select net.http_post(
    url     := (select decrypted_secret from vault.decrypted_secrets where name = 'project_url') || '/functions/v1/limpiar-historias',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'service_role_key')),
    body    := '{}'::jsonb
  );
$$);
