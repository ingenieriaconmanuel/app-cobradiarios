-- =====================================================================
-- 07. Tareas programadas (pg_cron). Horario en UTC: 10:00 UTC = 5:00 a.m. Colombia
-- =====================================================================
create extension if not exists pg_cron;

select cron.schedule('mora-diaria', '0 10 * * *', $$ select app.actualizar_mora() $$);

-- Suspende tenants con prueba vencida o suscripción vencida (3 días de gracia)
create or replace function app.suspender_vencidos() returns int
language plpgsql security definer set search_path = public as $$
declare v int;
begin
  update tenants t set estado = 'suspendido'
  where (t.estado = 'prueba' and t.prueba_hasta < app.hoy() - 3)
     or (t.estado = 'activo' and not exists (
           select 1 from suscripciones s where s.tenant_id = t.id and s.fin >= app.hoy() - 3));
  get diagnostics v = row_count;
  return v;
end $$;
revoke execute on function app.suspender_vencidos() from authenticated;

select cron.schedule('suspender-vencidos', '30 10 * * *', $$ select app.suspender_vencidos() $$);
