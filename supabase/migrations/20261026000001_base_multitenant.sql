-- =====================================================================
-- 01. Base multitenant: planes, tenants, suscripciones, perfiles, auditoría
-- Una sola base de datos. Cada tabla de negocio lleva tenant_id y RLS.
-- =====================================================================

create extension if not exists pgcrypto;
create schema if not exists app;

create type rol_usuario   as enum ('admin', 'supervisor', 'cobrador');
create type estado_tenant as enum ('prueba', 'activo', 'suspendido', 'cancelado');
create type periodo_pago  as enum ('mensual', 'anual');

-- ---------------------------------------------------------------------
-- Planes del SaaS (precios en COP)
-- ---------------------------------------------------------------------
create table planes (
  id                        text primary key,
  nombre                    text not null,
  precio_mensual            numeric(14,2) not null,
  precio_anual              numeric(14,2) not null,
  max_cobradores            int,            -- null = ilimitado
  max_clientes_activos      int,            -- null = ilimitado
  precio_cobrador_adicional numeric(14,2) not null default 0,
  activo                    boolean not null default true
);

insert into planes values
  ('emprendedor', 'Emprendedor',  59900,  599000,  1,  300, 29900, true),
  ('ruta_pro',    'Ruta Pro',    149900, 1499000,  3, 1000, 29900, true),
  ('empresa',     'Empresa',     349900, 3499000, 10, null, 29900, true);

-- ---------------------------------------------------------------------
-- Tenants (cada empresa prestamista)
-- ---------------------------------------------------------------------
create table tenants (
  id                     uuid primary key default gen_random_uuid(),
  nombre                 text not null,
  nit                    text,
  telefono               text,
  ciudad                 text,
  plan_id                text not null default 'emprendedor' references planes(id),
  cobradores_adicionales int  not null default 0,
  estado                 estado_tenant not null default 'prueba',
  prueba_hasta           date not null default (current_date + 14),
  -- politica_usura: 'bloquear' | 'advertir'; modalidad_usura: 'consumo_ordinario' | 'microcredito'
  config                 jsonb not null default
                           '{"politica_usura":"bloquear","modalidad_usura":"consumo_ordinario","saltar_domingos":true,"saltar_festivos":true}',
  creado_en              timestamptz not null default now()
);

create table suscripciones (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references tenants(id) on delete cascade,
  plan_id         text not null references planes(id),
  periodo         periodo_pago not null,
  valor           numeric(14,2) not null,
  inicio          date not null,
  fin             date not null,
  pasarela        text,           -- wompi, transferencia, nequi...
  referencia_pago text unique,
  creado_en       timestamptz not null default now()
);
create index on suscripciones (tenant_id, fin desc);

-- ---------------------------------------------------------------------
-- Perfiles: 1 a 1 con auth.users. tenant_id null solo para superadmin.
-- ---------------------------------------------------------------------
create table perfiles (
  id            uuid primary key references auth.users(id) on delete cascade,
  tenant_id     uuid references tenants(id) on delete cascade,
  nombre        text not null,
  telefono      text,
  documento     text,
  rol           rol_usuario not null default 'cobrador',
  es_superadmin boolean not null default false,
  activo        boolean not null default true,
  creado_en     timestamptz not null default now(),
  constraint perfil_con_tenant check (es_superadmin or tenant_id is not null)
);
create index on perfiles (tenant_id);

-- ---------------------------------------------------------------------
-- Helpers de sesión (security definer para no recursar en RLS)
-- ---------------------------------------------------------------------
create or replace function app.tenant_id() returns uuid
language sql stable security definer set search_path = public as $$
  select tenant_id from perfiles where id = auth.uid() and activo
$$;

create or replace function app.rol() returns rol_usuario
language sql stable security definer set search_path = public as $$
  select rol from perfiles where id = auth.uid() and activo
$$;

create or replace function app.es_superadmin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select es_superadmin from perfiles where id = auth.uid() and activo), false)
$$;

create or replace function app.es_gestor() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(app.rol() in ('admin', 'supervisor'), false)
$$;

-- Fecha de hoy en Colombia (el servidor corre en UTC)
create or replace function app.hoy() returns date
language sql stable as $$
  select (now() at time zone 'America/Bogota')::date
$$;

-- El tenant puede operar (escribir) si está activo o en prueba vigente
create or replace function app.tenant_operativo() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from tenants t
    where t.id = app.tenant_id()
      and (t.estado = 'activo' or (t.estado = 'prueba' and t.prueba_hasta >= app.hoy()))
  )
$$;

create or replace function app.exigir_operativo() returns void
language plpgsql stable as $$
begin
  if auth.uid() is null or app.tenant_id() is null then
    raise exception 'Sesión inválida o usuario sin empresa' using errcode = '42501';
  end if;
  if not app.tenant_operativo() then
    raise exception 'La suscripción de la empresa no está activa' using errcode = 'P0001';
  end if;
end $$;

create or replace function app.exigir_gestor() returns void
language plpgsql stable as $$
begin
  if not app.es_gestor() then
    raise exception 'Solo administradores o supervisores' using errcode = '42501';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- Auditoría genérica
-- ---------------------------------------------------------------------
create table auditoria (
  id          bigint generated always as identity primary key,
  tenant_id   uuid,
  tabla       text not null,
  registro_id text,
  accion      text not null,
  datos       jsonb,
  usuario_id  uuid,
  fecha       timestamptz not null default now()
);
create index on auditoria (tenant_id, fecha desc);

create or replace function app.auditar() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_fila jsonb;
begin
  v_fila := case when tg_op = 'DELETE' then to_jsonb(old) else to_jsonb(new) end;
  insert into auditoria (tenant_id, tabla, registro_id, accion, datos, usuario_id)
  values ((v_fila ->> 'tenant_id')::uuid, tg_table_name, v_fila ->> 'id', tg_op,
          case when tg_op = 'UPDATE' then jsonb_build_object('antes', to_jsonb(old), 'despues', v_fila) else v_fila end,
          auth.uid());
  return null;
end $$;

create trigger auditar_perfiles after insert or update or delete on perfiles
  for each row execute function app.auditar();
create trigger auditar_tenants after update on tenants
  for each row execute function app.auditar();

-- ---------------------------------------------------------------------
-- Límite de cobradores por plan
-- ---------------------------------------------------------------------
create or replace function app.validar_limite_cobradores() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_max int; v_actuales int;
begin
  if new.rol <> 'cobrador' or not new.activo or new.tenant_id is null then
    return new;
  end if;
  select p.max_cobradores + t.cobradores_adicionales into v_max
    from tenants t join planes p on p.id = t.plan_id where t.id = new.tenant_id;
  if v_max is null then return new; end if;
  select count(*) into v_actuales from perfiles
    where tenant_id = new.tenant_id and rol = 'cobrador' and activo and id <> new.id;
  if v_actuales >= v_max then
    raise exception 'Su plan permite % cobrador(es). Agregue cobradores adicionales o cambie de plan.', v_max;
  end if;
  return new;
end $$;

create trigger limite_cobradores before insert or update of rol, activo on perfiles
  for each row execute function app.validar_limite_cobradores();

-- ---------------------------------------------------------------------
-- Registro de empresa: el usuario recién registrado crea su tenant
-- ---------------------------------------------------------------------
create or replace function registrar_empresa(
  p_nombre_empresa text, p_nombre_admin text,
  p_nit text default null, p_telefono text default null, p_ciudad text default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_tenant uuid;
begin
  if auth.uid() is null then raise exception 'Debe iniciar sesión'; end if;
  if exists (select 1 from perfiles where id = auth.uid()) then
    raise exception 'El usuario ya pertenece a una empresa';
  end if;
  insert into tenants (nombre, nit, telefono, ciudad)
    values (p_nombre_empresa, p_nit, p_telefono, p_ciudad) returning id into v_tenant;
  insert into perfiles (id, tenant_id, nombre, telefono, rol)
    values (auth.uid(), v_tenant, p_nombre_admin, p_telefono, 'admin');
  return v_tenant;
end $$;
