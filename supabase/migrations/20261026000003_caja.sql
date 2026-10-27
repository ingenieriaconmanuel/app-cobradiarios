-- =====================================================================
-- 03. Caja diaria por cobrador: base, cobros, desembolsos, gastos, cierre
-- =====================================================================

create type estado_caja     as enum ('abierta', 'cerrada');
create type tipo_movimiento as enum ('base', 'cobro', 'desembolso', 'gasto', 'anulacion', 'ajuste');

create table cajas (
  id                 uuid primary key default gen_random_uuid(),
  tenant_id          uuid not null references tenants(id) on delete cascade,
  usuario_id         uuid not null references perfiles(id),
  fecha              date not null,
  estado             estado_caja not null default 'abierta',
  -- Se llenan al cerrar
  total_base         numeric(14,2),
  total_cobrado      numeric(14,2),
  total_desembolsado numeric(14,2),
  total_gastos       numeric(14,2),
  esperado           numeric(14,2),
  efectivo_entregado numeric(14,2),
  diferencia         numeric(14,2),
  cerrada_en         timestamptz,
  cerrada_por        uuid references perfiles(id),
  unique (tenant_id, usuario_id, fecha)
);

alter table pagos add constraint pagos_caja_fk foreign key (caja_id) references cajas(id);

-- valor con signo: + entra efectivo, - sale efectivo
create table movimientos_caja (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references tenants(id) on delete cascade,
  caja_id       uuid not null references cajas(id) on delete cascade,
  tipo          tipo_movimiento not null,
  valor         numeric(14,2) not null,
  referencia_id uuid,
  descripcion   text,
  usuario_id    uuid references perfiles(id),
  creado_en     timestamptz not null default now()
);
create index on movimientos_caja (caja_id);

create table gastos (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references tenants(id) on delete cascade,
  caja_id     uuid not null references cajas(id),
  usuario_id  uuid not null references perfiles(id),
  concepto    text not null,
  valor       numeric(14,2) not null check (valor > 0),
  soporte_url text,
  creado_en   timestamptz not null default now()
);

-- Caja abierta de hoy para un usuario (la crea si no existe)
create or replace function app.caja_de_hoy(p_usuario uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_caja uuid; v_estado estado_caja; v_tenant uuid;
begin
  select tenant_id into v_tenant from perfiles where id = p_usuario;
  insert into cajas (tenant_id, usuario_id, fecha)
    values (v_tenant, p_usuario, app.hoy())
    on conflict (tenant_id, usuario_id, fecha) do nothing;
  select id, estado into v_caja, v_estado from cajas
    where tenant_id = v_tenant and usuario_id = p_usuario and fecha = app.hoy();
  if v_estado = 'cerrada' then
    raise exception 'La caja de hoy ya fue cerrada. Pida al supervisor reabrirla.';
  end if;
  return v_caja;
end $$;

create trigger auditar_cajas after update on cajas
  for each row execute function app.auditar();
