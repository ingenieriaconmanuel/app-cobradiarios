-- =====================================================================
-- 04. Festivos de Colombia (Ley 51 de 1983, "Ley Emiliani") y tasa de usura
-- =====================================================================

create table festivos (
  fecha  date primary key,
  nombre text not null
);

-- Domingo de Pascua (algoritmo gregoriano anónimo / Meeus)
create or replace function app.domingo_pascua(p_anio int) returns date
language plpgsql immutable as $$
declare a int; b int; c int; d int; e int; f int; g int; h int; i int; k int; l int; m int;
begin
  a := p_anio % 19;  b := p_anio / 100;  c := p_anio % 100;
  d := b / 4;        e := b % 4;         f := (b + 8) / 25;
  g := (b - f + 1) / 3;
  h := (19 * a + b - d - g + 15) % 30;
  i := c / 4;        k := c % 4;
  l := (32 + 2 * e + 2 * i - h - k) % 7;
  m := (a + 11 * h + 22 * l) / 451;
  return make_date(p_anio, (h + l - 7 * m + 114) / 31, ((h + l - 7 * m + 114) % 31) + 1);
end $$;

-- Lunes siguiente (o el mismo día si ya es lunes)
create or replace function app.lunes_siguiente(p_fecha date) returns date
language sql immutable as $$
  select p_fecha + ((8 - extract(isodow from p_fecha)::int) % 7)
$$;

create or replace function app.festivos_colombia(p_anio int)
returns table (fecha date, nombre text)
language sql immutable as $$
  with p as (select app.domingo_pascua(p_anio) as pascua)
  select * from (values
    (make_date(p_anio, 1, 1),                       'Año Nuevo'),
    (app.lunes_siguiente(make_date(p_anio, 1, 6)),  'Reyes Magos'),
    (app.lunes_siguiente(make_date(p_anio, 3, 19)), 'San José'),
    ((select pascua from p) - 3,                    'Jueves Santo'),
    ((select pascua from p) - 2,                    'Viernes Santo'),
    (make_date(p_anio, 5, 1),                       'Día del Trabajo'),
    ((select pascua from p) + 43,                   'Ascensión del Señor'),
    ((select pascua from p) + 64,                   'Corpus Christi'),
    ((select pascua from p) + 71,                   'Sagrado Corazón'),
    (app.lunes_siguiente(make_date(p_anio, 6, 29)), 'San Pedro y San Pablo'),
    (make_date(p_anio, 7, 20),                      'Independencia de Colombia'),
    (make_date(p_anio, 8, 7),                       'Batalla de Boyacá'),
    (app.lunes_siguiente(make_date(p_anio, 8, 15)), 'Asunción de la Virgen'),
    (app.lunes_siguiente(make_date(p_anio, 10, 12)),'Día de la Raza'),
    (app.lunes_siguiente(make_date(p_anio, 11, 1)), 'Todos los Santos'),
    (app.lunes_siguiente(make_date(p_anio, 11, 11)),'Independencia de Cartagena'),
    (make_date(p_anio, 12, 8),                      'Inmaculada Concepción'),
    (make_date(p_anio, 12, 25),                     'Navidad')
  ) as v(fecha, nombre)
$$;

insert into festivos
  select distinct on (f.fecha) f.fecha, f.nombre
  from generate_series(2025, 2040) as anio, app.festivos_colombia(anio) f
  order by f.fecha
on conflict do nothing;

-- Corre la fecha hacia adelante hasta un día hábil de cobro
create or replace function app.ajustar_dia_cobro(p_fecha date, p_saltar_domingos boolean, p_saltar_festivos boolean)
returns date language plpgsql stable as $$
declare v date := p_fecha;
begin
  loop
    if p_saltar_domingos and extract(isodow from v) = 7 then
      v := v + 1;
    elsif p_saltar_festivos and exists (select 1 from festivos where fecha = v) then
      v := v + 1;
    else
      return v;
    end if;
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- Tasa de usura certificada por la Superintendencia Financiera.
-- CARGAR CADA MES: https://www.superfinanciera.gov.co (Interés bancario corriente)
-- ---------------------------------------------------------------------
create table tasas_usura (
  modalidad     text not null check (modalidad in ('consumo_ordinario', 'microcredito')),
  vigente_desde date not null,
  vigente_hasta date not null,
  tasa_ea       numeric(9,6) not null,   -- 0.2500 = 25 % E.A.
  primary key (modalidad, vigente_desde)
);

-- TIR periódica por bisección: capital = sum(cuota_i / (1+r)^i)
create or replace function app.tir_periodica(p_capital numeric, p_cuotas numeric[])
returns numeric language plpgsql immutable as $$
declare lo numeric := 0; hi numeric := 1; mid numeric; vp numeric; i int;
begin
  for iter in 1..80 loop
    mid := (lo + hi) / 2;
    vp := 0;
    for i in 1..array_length(p_cuotas, 1) loop
      vp := vp + p_cuotas[i] / power(1 + mid, i);
    end loop;
    if vp > p_capital then lo := mid; else hi := mid; end if;
  end loop;
  return (lo + hi) / 2;
end $$;

create or replace function app.periodos_por_anio(p_frecuencia frecuencia_pago, p_saltar_domingos boolean)
returns int language sql immutable as $$
  select case p_frecuencia
    when 'diario'    then case when p_saltar_domingos then 313 else 365 end
    when 'semanal'   then 52
    when 'quincenal' then 24
    when 'mensual'   then 12
  end
$$;

-- Lectura pública (solo lectura) de calendario y usura
alter table festivos    enable row level security;
alter table tasas_usura enable row level security;
create policy festivos_lectura on festivos    for select to authenticated using (true);
create policy usura_lectura    on tasas_usura for select to authenticated using (true);
