-- =====================================================================
-- 02. Cartera: rutas, clientes, préstamos, cuotas, pagos, gestiones
-- Montos en numeric(14,2). Nunca float.
-- =====================================================================

create type frecuencia_pago as enum ('diario', 'semanal', 'quincenal', 'mensual');
create type tipo_interes    as enum ('flat', 'frances', 'solo_interes');
create type estado_prestamo as enum ('activo', 'pagado', 'renovado', 'castigado', 'anulado');
create type estado_cuota    as enum ('pendiente', 'parcial', 'pagada', 'vencida');
create type metodo_pago     as enum ('efectivo', 'transferencia', 'nequi', 'daviplata', 'otro');
create type tipo_gestion    as enum ('visita', 'llamada', 'whatsapp', 'promesa_pago', 'no_encontrado', 'otro');

-- ---------------------------------------------------------------------
create table rutas (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references tenants(id) on delete cascade,
  nombre      text not null,
  descripcion text,
  activa      boolean not null default true,
  creado_en   timestamptz not null default now(),
  unique (tenant_id, nombre)
);

create table rutas_usuarios (
  ruta_id    uuid not null references rutas(id) on delete cascade,
  usuario_id uuid not null references perfiles(id) on delete cascade,
  tenant_id  uuid not null references tenants(id) on delete cascade,
  primary key (ruta_id, usuario_id)
);
create index on rutas_usuarios (usuario_id);

create or replace function app.mis_rutas() returns setof uuid
language sql stable security definer set search_path = public as $$
  select ruta_id from rutas_usuarios where usuario_id = auth.uid()
$$;

-- El cobrador solo ve lo de sus rutas; admin y supervisor ven todo el tenant
create or replace function app.puede_ver_ruta(p_ruta uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select app.es_gestor() or p_ruta in (select app.mis_rutas())
$$;

-- ---------------------------------------------------------------------
create table clientes (
  id                   uuid primary key default gen_random_uuid(),
  tenant_id            uuid not null references tenants(id) on delete cascade,
  ruta_id              uuid references rutas(id),
  documento            text not null,
  nombre               text not null,
  telefono             text,
  direccion            text,
  barrio               text,
  negocio              text,
  lat                  double precision,
  lng                  double precision,
  foto_url             text,
  referencia_nombre    text,
  referencia_telefono  text,
  autoriza_datos       boolean not null default false,  -- Ley 1581 de 2012
  autoriza_datos_fecha timestamptz,
  notas                text,
  activo               boolean not null default true,
  creado_por           uuid default auth.uid() references perfiles(id),
  creado_en            timestamptz not null default now(),
  unique (tenant_id, documento)
);
create index on clientes (tenant_id, ruta_id);
create index on clientes (tenant_id, nombre);

-- Defaults de tenant_id desde la sesión para simplificar los inserts del cliente
alter table rutas    alter column tenant_id set default app.tenant_id();
alter table clientes alter column tenant_id set default app.tenant_id();

create or replace function app.validar_limite_clientes() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_max int; v_actuales int;
begin
  if not new.activo then return new; end if;
  select p.max_clientes_activos into v_max
    from tenants t join planes p on p.id = t.plan_id where t.id = new.tenant_id;
  if v_max is null then return new; end if;
  select count(*) into v_actuales from clientes
    where tenant_id = new.tenant_id and activo and id <> new.id;
  if v_actuales >= v_max then
    raise exception 'Su plan permite % clientes activos. Cambie de plan para agregar más.', v_max;
  end if;
  if new.autoriza_datos and new.autoriza_datos_fecha is null then
    new.autoriza_datos_fecha := now();
  end if;
  return new;
end $$;

create trigger limite_clientes before insert or update of activo on clientes
  for each row execute function app.validar_limite_clientes();

-- ---------------------------------------------------------------------
-- Préstamos.
-- Semántica de `tasa`:
--   flat          -> tasa TOTAL sobre el capital por todo el plazo (0.20 = 20 %)
--   frances       -> tasa POR PERIODO (0.02 = 2 % mensual si frecuencia = mensual)
--   solo_interes  -> tasa POR PERIODO
-- ---------------------------------------------------------------------
create table prestamos (
  id                  uuid primary key default gen_random_uuid(),
  tenant_id           uuid not null references tenants(id) on delete cascade,
  numero              bigint generated always as identity,
  cliente_id          uuid not null references clientes(id),
  ruta_id             uuid references rutas(id),
  capital             numeric(14,2) not null check (capital > 0),
  tasa                numeric(9,6)  not null check (tasa >= 0),
  tipo_interes        tipo_interes not null default 'flat',
  frecuencia          frecuencia_pago not null default 'diario',
  num_cuotas          int not null check (num_cuotas between 1 and 400),
  valor_cuota         numeric(14,2) not null,
  total_a_pagar       numeric(14,2) not null,
  saldo               numeric(14,2) not null,           -- capital + interés pendiente (sin mora)
  tasa_ea             numeric(12,6),                    -- tasa efectiva anual equivalente
  supera_usura        boolean not null default false,
  fecha_desembolso    date not null default app.hoy(),
  fecha_primera_cuota date not null,
  saltar_domingos     boolean not null default true,
  saltar_festivos     boolean not null default true,
  mora_pct_diaria     numeric(7,5) not null default 0,  -- 0.001 = 0,1 % diario sobre lo vencido
  dias_gracia         int not null default 0,
  estado              estado_prestamo not null default 'activo',
  prestamo_origen_id  uuid references prestamos(id),    -- renovación
  notas               text,
  creado_por          uuid references perfiles(id),
  creado_en           timestamptz not null default now()
);
create index on prestamos (tenant_id, estado);
create index on prestamos (tenant_id, ruta_id, estado);
create index on prestamos (cliente_id);

create table cuotas (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references tenants(id) on delete cascade,
  prestamo_id       uuid not null references prestamos(id) on delete cascade,
  numero            int not null,
  fecha_vencimiento date not null,
  valor             numeric(14,2) not null,
  capital           numeric(14,2) not null,
  interes           numeric(14,2) not null,
  pagado            numeric(14,2) not null default 0,
  mora              numeric(14,2) not null default 0,
  mora_pagada       numeric(14,2) not null default 0,
  estado            estado_cuota not null default 'pendiente',
  unique (prestamo_id, numero)
);
create index on cuotas (tenant_id, fecha_vencimiento) where estado <> 'pagada';

-- El id lo genera el teléfono (UUID v4) para que la sincronización offline sea idempotente
create table pagos (
  id             uuid primary key,
  tenant_id      uuid not null references tenants(id) on delete cascade,
  prestamo_id    uuid not null references prestamos(id),
  cobrador_id    uuid not null references perfiles(id),
  caja_id        uuid,                  -- FK en migración 03
  valor          numeric(14,2) not null check (valor > 0),
  metodo         metodo_pago not null default 'efectivo',
  fecha          timestamptz not null,  -- cuándo se cobró (en el teléfono)
  lat            double precision,
  lng            double precision,
  anulado        boolean not null default false,
  anulado_por    uuid references perfiles(id),
  anulado_motivo text,
  creado_en      timestamptz not null default now()  -- cuándo llegó al servidor
);
create index on pagos (tenant_id, fecha desc);
create index on pagos (prestamo_id);

create table pago_aplicaciones (
  pago_id     uuid not null references pagos(id) on delete cascade,
  cuota_id    uuid not null references cuotas(id) on delete cascade,
  tenant_id   uuid not null references tenants(id) on delete cascade,
  valor_cuota numeric(14,2) not null default 0,
  valor_mora  numeric(14,2) not null default 0,
  primary key (pago_id, cuota_id)
);

create table gestiones_cobro (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null default app.tenant_id() references tenants(id) on delete cascade,
  prestamo_id    uuid not null references prestamos(id) on delete cascade,
  usuario_id     uuid not null default auth.uid() references perfiles(id),
  tipo           tipo_gestion not null,
  nota           text,
  fecha_promesa  date,
  lat            double precision,
  lng            double precision,
  creado_en      timestamptz not null default now()
);
create index on gestiones_cobro (prestamo_id, creado_en desc);

create trigger auditar_prestamos after insert or update or delete on prestamos
  for each row execute function app.auditar();
create trigger auditar_pagos after insert or update on pagos
  for each row execute function app.auditar();
