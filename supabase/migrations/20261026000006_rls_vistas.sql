-- =====================================================================
-- 06. Row Level Security, permisos y vistas
-- Regla: las tablas de dinero (prestamos, cuotas, pagos, cajas, movimientos,
-- gastos) son de SOLO LECTURA para el cliente; se escriben solo vía RPC.
-- =====================================================================

alter table planes            enable row level security;
alter table tenants           enable row level security;
alter table suscripciones     enable row level security;
alter table perfiles          enable row level security;
alter table auditoria         enable row level security;
alter table rutas             enable row level security;
alter table rutas_usuarios    enable row level security;
alter table clientes          enable row level security;
alter table prestamos         enable row level security;
alter table cuotas            enable row level security;
alter table pagos             enable row level security;
alter table pago_aplicaciones enable row level security;
alter table gestiones_cobro   enable row level security;
alter table cajas             enable row level security;
alter table movimientos_caja  enable row level security;
alter table gastos            enable row level security;

-- Permisos base: nada para anon; lectura para authenticated (RLS filtra)
revoke all on all tables in schema public from anon;
grant select on all tables in schema public to authenticated;
grant usage on schema app to authenticated;
grant execute on all functions in schema app to authenticated;

-- Escrituras directas permitidas (el resto solo por RPC)
grant insert, update        on rutas, clientes        to authenticated;
grant insert, delete        on rutas_usuarios         to authenticated;
grant insert                on gestiones_cobro        to authenticated;
grant update (nombre, nit, telefono, ciudad, config) on tenants to authenticated;
grant update (nombre, telefono, documento, rol, activo) on perfiles to authenticated;

-- ---------------------------------------------------------------------
-- Catálogos
-- ---------------------------------------------------------------------
create policy planes_lectura on planes for select to authenticated using (activo or app.es_superadmin());

-- ---------------------------------------------------------------------
-- Tenant / suscripciones / perfiles
-- ---------------------------------------------------------------------
create policy tenant_lectura on tenants for select to authenticated
  using (id = app.tenant_id() or app.es_superadmin());
create policy tenant_edicion on tenants for update to authenticated
  using (id = app.tenant_id() and app.rol() = 'admin')
  with check (id = app.tenant_id());

create policy suscripciones_lectura on suscripciones for select to authenticated
  using ((tenant_id = app.tenant_id() and app.rol() = 'admin') or app.es_superadmin());

create policy perfiles_lectura on perfiles for select to authenticated
  using (tenant_id = app.tenant_id() or id = auth.uid() or app.es_superadmin());
create policy perfiles_edicion on perfiles for update to authenticated
  using (tenant_id = app.tenant_id() and app.rol() = 'admin' and app.tenant_operativo())
  with check (tenant_id = app.tenant_id() and (id <> auth.uid() or rol = 'admin'));  -- el admin no se degrada a sí mismo

create policy auditoria_lectura on auditoria for select to authenticated
  using ((tenant_id = app.tenant_id() and app.rol() = 'admin') or app.es_superadmin());

-- ---------------------------------------------------------------------
-- Rutas
-- ---------------------------------------------------------------------
create policy rutas_lectura on rutas for select to authenticated
  using (tenant_id = app.tenant_id() and app.puede_ver_ruta(id));
create policy rutas_insert on rutas for insert to authenticated
  with check (tenant_id = app.tenant_id() and app.es_gestor() and app.tenant_operativo());
create policy rutas_update on rutas for update to authenticated
  using (tenant_id = app.tenant_id() and app.es_gestor())
  with check (tenant_id = app.tenant_id());

create policy rutas_usuarios_lectura on rutas_usuarios for select to authenticated
  using (tenant_id = app.tenant_id());
create policy rutas_usuarios_insert on rutas_usuarios for insert to authenticated
  with check (tenant_id = app.tenant_id() and app.es_gestor()
              and exists (select 1 from rutas r where r.id = ruta_id and r.tenant_id = app.tenant_id())
              and exists (select 1 from perfiles u where u.id = usuario_id and u.tenant_id = app.tenant_id()));
create policy rutas_usuarios_delete on rutas_usuarios for delete to authenticated
  using (tenant_id = app.tenant_id() and app.es_gestor());

-- ---------------------------------------------------------------------
-- Clientes
-- ---------------------------------------------------------------------
create policy clientes_lectura on clientes for select to authenticated
  using (tenant_id = app.tenant_id() and app.puede_ver_ruta(ruta_id));
create policy clientes_insert on clientes for insert to authenticated
  with check (tenant_id = app.tenant_id() and app.tenant_operativo() and app.puede_ver_ruta(ruta_id));
create policy clientes_update on clientes for update to authenticated
  using (tenant_id = app.tenant_id() and app.puede_ver_ruta(ruta_id))
  with check (tenant_id = app.tenant_id() and app.tenant_operativo() and app.puede_ver_ruta(ruta_id));

-- ---------------------------------------------------------------------
-- Dinero: solo lectura
-- ---------------------------------------------------------------------
create policy prestamos_lectura on prestamos for select to authenticated
  using (tenant_id = app.tenant_id() and app.puede_ver_ruta(ruta_id));

create policy cuotas_lectura on cuotas for select to authenticated
  using (tenant_id = app.tenant_id()
         and exists (select 1 from prestamos p where p.id = prestamo_id));  -- hereda el filtro de ruta

create policy pagos_lectura on pagos for select to authenticated
  using (tenant_id = app.tenant_id()
         and (cobrador_id = auth.uid() or app.es_gestor()));

create policy pago_aplicaciones_lectura on pago_aplicaciones for select to authenticated
  using (tenant_id = app.tenant_id() and exists (select 1 from pagos p where p.id = pago_id));

create policy gestiones_lectura on gestiones_cobro for select to authenticated
  using (tenant_id = app.tenant_id() and exists (select 1 from prestamos p where p.id = prestamo_id));
create policy gestiones_insert on gestiones_cobro for insert to authenticated
  with check (tenant_id = app.tenant_id() and usuario_id = auth.uid() and app.tenant_operativo()
              and exists (select 1 from prestamos p where p.id = prestamo_id));

create policy cajas_lectura on cajas for select to authenticated
  using (tenant_id = app.tenant_id() and (usuario_id = auth.uid() or app.es_gestor()));
create policy movimientos_lectura on movimientos_caja for select to authenticated
  using (tenant_id = app.tenant_id() and exists (select 1 from cajas c where c.id = caja_id));
create policy gastos_lectura on gastos for select to authenticated
  using (tenant_id = app.tenant_id() and (usuario_id = auth.uid() or app.es_gestor()));

-- ---------------------------------------------------------------------
-- RPC expuestas a la app
-- ---------------------------------------------------------------------
revoke execute on all functions in schema public from public, anon;
grant execute on function
  registrar_empresa(text, text, text, text, text),
  simular_prestamo(numeric, numeric, int, frecuencia_pago, tipo_interes, date, boolean, boolean),
  crear_prestamo(uuid, numeric, numeric, int, frecuencia_pago, tipo_interes, date, boolean, boolean, numeric, int, uuid, text),
  registrar_pago(uuid, uuid, numeric, metodo_pago, timestamptz, double precision, double precision),
  anular_pago(uuid, text),
  asignar_base(uuid, numeric),
  registrar_gasto(text, numeric, text),
  cerrar_caja(uuid, numeric),
  reabrir_caja(uuid)
to authenticated;
-- Internas: solo las llaman otras funciones security definer o pg_cron
revoke execute on function app.actualizar_mora() from authenticated;
revoke execute on function app.caja_de_hoy(uuid) from authenticated;
revoke execute on function app.auditar() from authenticated;

-- ---------------------------------------------------------------------
-- Vistas (security_invoker: respetan el RLS de quien consulta)
-- ---------------------------------------------------------------------

-- Lo que el cobrador debe cobrar hoy: cuotas vencidas o de hoy, agrupadas por préstamo
create view v_cobros_del_dia with (security_invoker = true) as
select
  p.id                     as prestamo_id,
  p.numero                 as prestamo_numero,
  p.tenant_id,
  p.ruta_id,
  cl.id                    as cliente_id,
  cl.nombre                as cliente_nombre,
  cl.telefono, cl.direccion, cl.barrio, cl.lat, cl.lng,
  p.valor_cuota,
  p.saldo,
  count(c.id)                                         as cuotas_pendientes,
  sum(c.valor - c.pagado)                             as valor_vencido,
  sum(c.mora - c.mora_pagada)                         as mora_pendiente,
  sum(c.valor - c.pagado + c.mora - c.mora_pagada)    as total_a_cobrar_hoy,
  min(c.fecha_vencimiento)                            as cuota_mas_antigua,
  greatest(0, app.hoy() - min(c.fecha_vencimiento))   as dias_atraso,
  exists (select 1 from pagos pg where pg.prestamo_id = p.id and not pg.anulado
          and (pg.fecha at time zone 'America/Bogota')::date = app.hoy()) as pago_hoy
from prestamos p
join clientes cl on cl.id = p.cliente_id
join cuotas c on c.prestamo_id = p.id and c.estado <> 'pagada' and c.fecha_vencimiento <= app.hoy()
where p.estado = 'activo'
group by p.id, cl.id;

-- Resumen de cartera del tenant (dashboard)
create view v_resumen_cartera with (security_invoker = true) as
select
  p.tenant_id,
  count(*) filter (where p.estado = 'activo')                 as prestamos_activos,
  coalesce(sum(p.saldo) filter (where p.estado = 'activo'), 0) as cartera,
  coalesce(sum(p.capital) filter (where p.estado = 'activo'), 0) as capital_colocado,
  (select coalesce(sum(c.valor - c.pagado), 0) from cuotas c
     where c.tenant_id = p.tenant_id and c.estado = 'vencida')  as cartera_vencida,
  (select coalesce(sum(pg.valor), 0) from pagos pg
     where pg.tenant_id = p.tenant_id and not pg.anulado
       and (pg.fecha at time zone 'America/Bogota')::date = app.hoy()) as recaudo_hoy
from prestamos p
group by p.tenant_id;

grant select on v_cobros_del_dia, v_resumen_cartera to authenticated;
