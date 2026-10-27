-- =====================================================================
-- 05. Lógica de negocio (todo el dinero se calcula aquí, nunca en Flutter)
--     simular_prestamo, crear_prestamo (con renovación), registrar_pago,
--     anular_pago, actualizar_mora, asignar_base, registrar_gasto, cerrar_caja
-- =====================================================================

-- ---------------------------------------------------------------------
-- Plan de pagos
-- ---------------------------------------------------------------------
create or replace function app.calcular_plan(
  p_capital numeric, p_tasa numeric, p_num_cuotas int,
  p_frecuencia frecuencia_pago, p_tipo tipo_interes, p_primera date,
  p_saltar_domingos boolean, p_saltar_festivos boolean
) returns table (numero int, fecha_vencimiento date, valor numeric, capital numeric, interes numeric)
language plpgsql stable as $$
declare
  v_fecha date; v_base date; v_cuota numeric; v_cap numeric; v_int numeric;
  v_saldo numeric := p_capital; v_cap_acum numeric := 0; v_int_acum numeric := 0; v_int_total numeric;
begin
  if p_num_cuotas < 1 then raise exception 'Número de cuotas inválido'; end if;

  if p_tipo = 'flat' then
    v_int_total := round(p_capital * p_tasa, 0);
    v_cuota := round((p_capital + v_int_total) / p_num_cuotas, 0);
  elsif p_tipo = 'frances' then
    v_cuota := case when p_tasa = 0 then round(p_capital / p_num_cuotas, 0)
                    else round(p_capital * p_tasa / (1 - power(1 + p_tasa, -p_num_cuotas)), 0) end;
  end if;

  for n in 1..p_num_cuotas loop
    v_base := case p_frecuencia
      when 'diario'    then case when n = 1 then p_primera else v_fecha + 1 end
      when 'semanal'   then p_primera + (n - 1) * 7
      when 'quincenal' then p_primera + (n - 1) * 15
      else (p_primera + make_interval(months => n - 1))::date
    end;
    v_fecha := app.ajustar_dia_cobro(v_base, p_saltar_domingos, p_saltar_festivos);

    if p_tipo = 'flat' then
      if n < p_num_cuotas then
        v_cap := round(p_capital / p_num_cuotas, 0);
        v_int := v_cuota - v_cap;
      else
        v_cap := p_capital - v_cap_acum;
        v_int := v_int_total - v_int_acum;
      end if;
    elsif p_tipo = 'frances' then
      v_int := round(v_saldo * p_tasa, 0);
      v_cap := case when n < p_num_cuotas then v_cuota - v_int else v_saldo end;
    else -- solo_interes
      v_int := round(p_capital * p_tasa, 0);
      v_cap := case when n < p_num_cuotas then 0 else p_capital end;
    end if;

    v_saldo := v_saldo - v_cap;
    v_cap_acum := v_cap_acum + v_cap;
    v_int_acum := v_int_acum + v_int;

    numero := n; fecha_vencimiento := v_fecha;
    capital := v_cap; interes := v_int; valor := v_cap + v_int;
    return next;
  end loop;
end $$;

create or replace function app.primera_cuota_default(p_frecuencia frecuencia_pago) returns date
language sql stable as $$
  select case p_frecuencia
    when 'diario'    then app.hoy() + 1
    when 'semanal'   then app.hoy() + 7
    when 'quincenal' then app.hoy() + 15
    else (app.hoy() + interval '1 month')::date
  end
$$;

-- ---------------------------------------------------------------------
-- Simulación (sin guardar). La usa Flutter para mostrar el plan antes de crear.
-- ---------------------------------------------------------------------
create or replace function simular_prestamo(
  p_capital numeric, p_tasa numeric, p_num_cuotas int,
  p_frecuencia frecuencia_pago default 'diario',
  p_tipo_interes tipo_interes default 'flat',
  p_fecha_primera_cuota date default null,
  p_saltar_domingos boolean default null,
  p_saltar_festivos boolean default null
) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_cfg jsonb; v_dom boolean; v_fest boolean; v_primera date;
  v_cuotas jsonb; v_valores numeric[]; v_total numeric;
  v_tir numeric; v_ea numeric; v_usura numeric;
begin
  select config into v_cfg from tenants where id = app.tenant_id();
  v_dom    := coalesce(p_saltar_domingos, (v_cfg ->> 'saltar_domingos')::boolean, true);
  v_fest   := coalesce(p_saltar_festivos, (v_cfg ->> 'saltar_festivos')::boolean, true);
  v_primera := coalesce(p_fecha_primera_cuota, app.primera_cuota_default(p_frecuencia));

  select jsonb_agg(to_jsonb(c) order by c.numero), array_agg(c.valor order by c.numero), sum(c.valor)
    into v_cuotas, v_valores, v_total
    from app.calcular_plan(p_capital, p_tasa, p_num_cuotas, p_frecuencia, p_tipo_interes, v_primera, v_dom, v_fest) c;

  v_tir := app.tir_periodica(p_capital, v_valores);
  v_ea  := power(1 + v_tir, app.periodos_por_anio(p_frecuencia, v_dom)) - 1;

  select tasa_ea into v_usura from tasas_usura
   where modalidad = coalesce(v_cfg ->> 'modalidad_usura', 'consumo_ordinario')
     and app.hoy() between vigente_desde and vigente_hasta;

  return jsonb_build_object(
    'capital',             p_capital,
    'valor_cuota',         v_valores[1],
    'total_a_pagar',       v_total,
    'interes_total',       v_total - p_capital,
    'fecha_primera_cuota', v_primera,
    'fecha_ultima_cuota',  v_cuotas -> -1 ->> 'fecha_vencimiento',
    'saltar_domingos',     v_dom,
    'saltar_festivos',     v_fest,
    'tasa_periodica',      round(v_tir, 6),
    'tasa_ea',             round(v_ea, 6),
    'tasa_usura_ea',       v_usura,
    'supera_usura',        coalesce(v_ea > v_usura, false),
    'politica_usura',      coalesce(v_cfg ->> 'politica_usura', 'bloquear'),
    'cuotas',              v_cuotas
  );
end $$;

-- ---------------------------------------------------------------------
-- Crear préstamo (opcionalmente renovando uno activo del mismo cliente)
-- ---------------------------------------------------------------------
create or replace function crear_prestamo(
  p_cliente_id uuid, p_capital numeric, p_tasa numeric, p_num_cuotas int,
  p_frecuencia frecuencia_pago default 'diario',
  p_tipo_interes tipo_interes default 'flat',
  p_fecha_primera_cuota date default null,
  p_saltar_domingos boolean default null,
  p_saltar_festivos boolean default null,
  p_mora_pct_diaria numeric default 0,
  p_dias_gracia int default 0,
  p_renovar_prestamo_id uuid default null,
  p_notas text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_tenant uuid := app.tenant_id();
  v_cliente clientes; v_sim jsonb; v_id uuid; v_caja uuid;
  v_anterior prestamos; v_saldo_anterior numeric := 0; v_neto numeric;
begin
  perform app.exigir_operativo();

  select * into v_cliente from clientes where id = p_cliente_id and tenant_id = v_tenant;
  if not found or not v_cliente.activo then raise exception 'Cliente no encontrado o inactivo'; end if;
  if not app.puede_ver_ruta(v_cliente.ruta_id) then raise exception 'No autorizado para esta ruta' using errcode = '42501'; end if;
  if p_capital <= 0 then raise exception 'El capital debe ser mayor a cero'; end if;

  v_sim := simular_prestamo(p_capital, p_tasa, p_num_cuotas, p_frecuencia, p_tipo_interes,
                            p_fecha_primera_cuota, p_saltar_domingos, p_saltar_festivos);

  if (v_sim ->> 'supera_usura')::boolean and v_sim ->> 'politica_usura' = 'bloquear' then
    raise exception 'La tasa efectiva anual (% %%) supera la tasa de usura vigente (% %%).',
      round((v_sim ->> 'tasa_ea')::numeric * 100, 2), round((v_sim ->> 'tasa_usura_ea')::numeric * 100, 2);
  end if;

  -- Renovación: el saldo (más mora pendiente) se descuenta del desembolso
  if p_renovar_prestamo_id is not null then
    select * into v_anterior from prestamos
      where id = p_renovar_prestamo_id and tenant_id = v_tenant and cliente_id = p_cliente_id and estado = 'activo'
      for update;
    if not found then raise exception 'El préstamo a renovar no existe o no está activo'; end if;
    select v_anterior.saldo + coalesce(sum(mora - mora_pagada), 0) into v_saldo_anterior
      from cuotas where prestamo_id = v_anterior.id and estado <> 'pagada';
    if p_capital <= v_saldo_anterior then
      raise exception 'El nuevo capital (%) debe ser mayor al saldo pendiente (%)', p_capital, v_saldo_anterior;
    end if;
    update cuotas set pagado = valor, mora_pagada = mora, estado = 'pagada'
      where prestamo_id = v_anterior.id and estado <> 'pagada';
    update prestamos set saldo = 0, estado = 'renovado' where id = v_anterior.id;
  end if;

  insert into prestamos (
    tenant_id, cliente_id, ruta_id, capital, tasa, tipo_interes, frecuencia, num_cuotas,
    valor_cuota, total_a_pagar, saldo, tasa_ea, supera_usura, fecha_desembolso, fecha_primera_cuota,
    saltar_domingos, saltar_festivos, mora_pct_diaria, dias_gracia, prestamo_origen_id, notas, creado_por
  ) values (
    v_tenant, p_cliente_id, v_cliente.ruta_id, p_capital, p_tasa, p_tipo_interes, p_frecuencia, p_num_cuotas,
    (v_sim ->> 'valor_cuota')::numeric, (v_sim ->> 'total_a_pagar')::numeric, (v_sim ->> 'total_a_pagar')::numeric,
    (v_sim ->> 'tasa_ea')::numeric, (v_sim ->> 'supera_usura')::boolean, app.hoy(),
    (v_sim ->> 'fecha_primera_cuota')::date,
    (v_sim ->> 'saltar_domingos')::boolean, (v_sim ->> 'saltar_festivos')::boolean,
    p_mora_pct_diaria, p_dias_gracia, p_renovar_prestamo_id, p_notas, auth.uid()
  ) returning id into v_id;

  insert into cuotas (tenant_id, prestamo_id, numero, fecha_vencimiento, valor, capital, interes)
    select v_tenant, v_id, (c ->> 'numero')::int, (c ->> 'fecha_vencimiento')::date,
           (c ->> 'valor')::numeric, (c ->> 'capital')::numeric, (c ->> 'interes')::numeric
      from jsonb_array_elements(v_sim -> 'cuotas') c;

  v_neto := p_capital - v_saldo_anterior;
  v_caja := app.caja_de_hoy(auth.uid());
  insert into movimientos_caja (tenant_id, caja_id, tipo, valor, referencia_id, descripcion, usuario_id)
    values (v_tenant, v_caja, 'desembolso', -v_neto, v_id,
            case when v_saldo_anterior > 0 then 'Renovación, saldo anterior ' || v_saldo_anterior else 'Desembolso' end,
            auth.uid());

  return jsonb_build_object('prestamo_id', v_id, 'efectivo_entregado', v_neto,
                            'saldo_renovado', v_saldo_anterior) || (v_sim - 'cuotas');
end $$;

-- ---------------------------------------------------------------------
-- Registrar pago (idempotente por p_id generado en el teléfono)
-- Se aplica primero a la mora y luego a la cuota, de la más antigua a la más nueva.
-- ---------------------------------------------------------------------
create or replace function registrar_pago(
  p_id uuid, p_prestamo_id uuid, p_valor numeric,
  p_metodo metodo_pago default 'efectivo',
  p_fecha timestamptz default now(),
  p_lat double precision default null, p_lng double precision default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_tenant uuid := app.tenant_id();
  v_p prestamos; v_c record; v_caja uuid;
  v_restante numeric := p_valor; v_a_mora numeric; v_a_cuota numeric;
  v_total_cuota numeric := 0; v_total_mora numeric := 0; v_deuda numeric;
begin
  perform app.exigir_operativo();

  -- Reintento de sincronización: devolver el resultado original
  if exists (select 1 from pagos where id = p_id) then
    return (select jsonb_build_object('pago_id', id, 'duplicado', true, 'prestamo_id', prestamo_id)
              from pagos where id = p_id and tenant_id = v_tenant);
  end if;

  if p_valor <= 0 then raise exception 'El valor del pago debe ser mayor a cero'; end if;

  select * into v_p from prestamos where id = p_prestamo_id and tenant_id = v_tenant for update;
  if not found then raise exception 'Préstamo no encontrado'; end if;
  if v_p.estado <> 'activo' then raise exception 'El préstamo no está activo (estado: %)', v_p.estado; end if;
  if not app.puede_ver_ruta(v_p.ruta_id) then raise exception 'No autorizado para esta ruta' using errcode = '42501'; end if;

  select v_p.saldo + coalesce(sum(mora - mora_pagada), 0) into v_deuda
    from cuotas where prestamo_id = v_p.id and estado <> 'pagada';
  if p_valor > v_deuda then
    raise exception 'El pago (%) supera la deuda total (%)', p_valor, v_deuda;
  end if;

  v_caja := app.caja_de_hoy(auth.uid());

  insert into pagos (id, tenant_id, prestamo_id, cobrador_id, caja_id, valor, metodo, fecha, lat, lng)
    values (p_id, v_tenant, v_p.id, auth.uid(), v_caja, p_valor, p_metodo, p_fecha, p_lat, p_lng);

  for v_c in
    select * from cuotas where prestamo_id = v_p.id and estado <> 'pagada' order by numero for update
  loop
    exit when v_restante <= 0;
    v_a_mora  := least(v_restante, v_c.mora - v_c.mora_pagada);
    v_restante := v_restante - v_a_mora;
    v_a_cuota := least(v_restante, v_c.valor - v_c.pagado);
    v_restante := v_restante - v_a_cuota;

    if v_a_mora + v_a_cuota > 0 then
      update cuotas set
        pagado      = pagado + v_a_cuota,
        mora_pagada = mora_pagada + v_a_mora,
        estado = case
          when pagado + v_a_cuota >= valor and mora_pagada + v_a_mora >= mora then 'pagada'::estado_cuota
          when fecha_vencimiento < app.hoy() then 'vencida'::estado_cuota
          else 'parcial'::estado_cuota end
      where id = v_c.id;
      insert into pago_aplicaciones (pago_id, cuota_id, tenant_id, valor_cuota, valor_mora)
        values (p_id, v_c.id, v_tenant, v_a_cuota, v_a_mora);
      v_total_cuota := v_total_cuota + v_a_cuota;
      v_total_mora  := v_total_mora + v_a_mora;
    end if;
  end loop;

  update prestamos set
    saldo  = saldo - v_total_cuota,
    estado = case when saldo - v_total_cuota <= 0
                   and not exists (select 1 from cuotas where prestamo_id = v_p.id and estado <> 'pagada')
                  then 'pagado'::estado_prestamo else estado end
  where id = v_p.id;

  insert into movimientos_caja (tenant_id, caja_id, tipo, valor, referencia_id, descripcion, usuario_id)
    values (v_tenant, v_caja, 'cobro', p_valor, p_id, 'Pago préstamo #' || v_p.numero, auth.uid());

  return jsonb_build_object(
    'pago_id', p_id, 'duplicado', false, 'prestamo_id', v_p.id,
    'aplicado_cuotas', v_total_cuota, 'aplicado_mora', v_total_mora,
    'saldo', v_p.saldo - v_total_cuota);
end $$;

-- ---------------------------------------------------------------------
-- Anular pago (solo admin/supervisor). Revierte cuotas, saldo y caja.
-- ---------------------------------------------------------------------
create or replace function anular_pago(p_pago_id uuid, p_motivo text) returns void
language plpgsql security definer set search_path = public as $$
declare v_pago pagos; v_caja uuid; v_total_cuota numeric;
begin
  perform app.exigir_operativo();
  perform app.exigir_gestor();
  if coalesce(trim(p_motivo), '') = '' then raise exception 'Debe indicar el motivo'; end if;

  select * into v_pago from pagos where id = p_pago_id and tenant_id = app.tenant_id() for update;
  if not found then raise exception 'Pago no encontrado'; end if;
  if v_pago.anulado then raise exception 'El pago ya está anulado'; end if;

  perform 1 from prestamos where id = v_pago.prestamo_id for update;

  update cuotas c set
    pagado      = c.pagado - a.valor_cuota,
    mora_pagada = c.mora_pagada - a.valor_mora,
    estado = case
      when c.fecha_vencimiento < app.hoy() then 'vencida'::estado_cuota
      when c.pagado - a.valor_cuota > 0 then 'parcial'::estado_cuota
      else 'pendiente'::estado_cuota end
  from pago_aplicaciones a
  where a.pago_id = p_pago_id and a.cuota_id = c.id;

  select coalesce(sum(valor_cuota), 0) into v_total_cuota from pago_aplicaciones where pago_id = p_pago_id;

  update prestamos set saldo = saldo + v_total_cuota,
                       estado = case when estado = 'pagado' then 'activo'::estado_prestamo else estado end
   where id = v_pago.prestamo_id;

  update pagos set anulado = true, anulado_por = auth.uid(), anulado_motivo = p_motivo where id = p_pago_id;

  -- Si la caja original sigue abierta se reversa ahí; si no, en la caja de hoy de quien anula
  select id into v_caja from cajas where id = v_pago.caja_id and estado = 'abierta';
  v_caja := coalesce(v_caja, app.caja_de_hoy(auth.uid()));
  insert into movimientos_caja (tenant_id, caja_id, tipo, valor, referencia_id, descripcion, usuario_id)
    values (v_pago.tenant_id, v_caja, 'anulacion', -v_pago.valor, p_pago_id, 'Anulación: ' || p_motivo, auth.uid());
end $$;

-- ---------------------------------------------------------------------
-- Mora diaria (pg_cron, 5:00 a.m. Colombia). Idempotente: recalcula, no acumula.
-- ---------------------------------------------------------------------
create or replace function app.actualizar_mora() returns int
language plpgsql security definer set search_path = public as $$
declare v_filas int;
begin
  update cuotas c set
    estado = 'vencida',
    mora = greatest(
      c.mora_pagada,
      round((c.valor - c.pagado) * p.mora_pct_diaria
            * greatest(0, app.hoy() - c.fecha_vencimiento - p.dias_gracia), 0))
  from prestamos p
  where p.id = c.prestamo_id
    and p.estado = 'activo'
    and c.estado <> 'pagada'
    and c.fecha_vencimiento < app.hoy();
  get diagnostics v_filas = row_count;
  return v_filas;
end $$;

-- ---------------------------------------------------------------------
-- Caja: base, gastos y cierre
-- ---------------------------------------------------------------------
create or replace function asignar_base(p_usuario_id uuid, p_valor numeric) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_caja uuid;
begin
  perform app.exigir_operativo();
  perform app.exigir_gestor();
  if not exists (select 1 from perfiles where id = p_usuario_id and tenant_id = app.tenant_id() and activo) then
    raise exception 'Usuario no encontrado';
  end if;
  if p_valor <= 0 then raise exception 'La base debe ser mayor a cero'; end if;
  v_caja := app.caja_de_hoy(p_usuario_id);
  insert into movimientos_caja (tenant_id, caja_id, tipo, valor, descripcion, usuario_id)
    values (app.tenant_id(), v_caja, 'base', p_valor, 'Base entregada', auth.uid());
  return v_caja;
end $$;

create or replace function registrar_gasto(p_concepto text, p_valor numeric, p_soporte_url text default null)
returns uuid
language plpgsql security definer set search_path = public as $$
declare v_caja uuid; v_id uuid;
begin
  perform app.exigir_operativo();
  if p_valor <= 0 then raise exception 'El gasto debe ser mayor a cero'; end if;
  v_caja := app.caja_de_hoy(auth.uid());
  insert into gastos (tenant_id, caja_id, usuario_id, concepto, valor, soporte_url)
    values (app.tenant_id(), v_caja, auth.uid(), p_concepto, p_valor, p_soporte_url) returning id into v_id;
  insert into movimientos_caja (tenant_id, caja_id, tipo, valor, referencia_id, descripcion, usuario_id)
    values (app.tenant_id(), v_caja, 'gasto', -p_valor, v_id, p_concepto, auth.uid());
  return v_id;
end $$;

create or replace function cerrar_caja(p_caja_id uuid, p_efectivo_entregado numeric) returns cajas
language plpgsql security definer set search_path = public as $$
declare v_caja cajas;
begin
  perform app.exigir_operativo();
  select * into v_caja from cajas where id = p_caja_id and tenant_id = app.tenant_id() for update;
  if not found then raise exception 'Caja no encontrada'; end if;
  if v_caja.usuario_id <> auth.uid() and not app.es_gestor() then
    raise exception 'No autorizado' using errcode = '42501';
  end if;
  if v_caja.estado = 'cerrada' then raise exception 'La caja ya está cerrada'; end if;

  update cajas c set
    total_base         = t.base,
    total_cobrado      = t.cobrado,
    total_desembolsado = t.desembolsado,
    total_gastos       = t.gastos,
    esperado           = t.neto,
    efectivo_entregado = p_efectivo_entregado,
    diferencia         = p_efectivo_entregado - t.neto,
    estado             = 'cerrada',
    cerrada_en         = now(),
    cerrada_por        = auth.uid()
  from (
    select coalesce(sum(valor) filter (where tipo = 'base'), 0)                         as base,
           coalesce(sum(valor) filter (where tipo in ('cobro', 'anulacion')), 0)        as cobrado,
           coalesce(-sum(valor) filter (where tipo = 'desembolso'), 0)                  as desembolsado,
           coalesce(-sum(valor) filter (where tipo = 'gasto'), 0)                       as gastos,
           coalesce(sum(valor), 0)                                                      as neto
      from movimientos_caja where caja_id = p_caja_id
  ) t
  where c.id = p_caja_id
  returning c.* into v_caja;
  return v_caja;
end $$;

create or replace function reabrir_caja(p_caja_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform app.exigir_gestor();
  update cajas set estado = 'abierta', cerrada_en = null, cerrada_por = null
   where id = p_caja_id and tenant_id = app.tenant_id();
end $$;
