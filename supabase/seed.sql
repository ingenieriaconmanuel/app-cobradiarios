-- Datos de ejemplo SOLO para desarrollo local (supabase db reset). No se aplica en producción.
-- Usuario demo: admin@demo.test / Demo12345
insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
                        raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                        confirmation_token, recovery_token, email_change_token_new, email_change)
values ('00000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000a1', 'authenticated',
        'authenticated', 'admin@demo.test', crypt('Demo12345', gen_salt('bf')), now(),
        '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', '', '', '');

insert into auth.identities (id, user_id, provider_id, identity_data, provider, created_at, updated_at)
values (gen_random_uuid(), '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a1',
        '{"sub":"00000000-0000-0000-0000-0000000000a1","email":"admin@demo.test"}', 'email', now(), now());

insert into tenants (id, nombre, ciudad, plan_id, estado, config)
values ('00000000-0000-0000-0000-0000000000f1', 'Créditos Demo', 'Bogotá', 'ruta_pro', 'activo',
        '{"politica_usura":"advertir","modalidad_usura":"consumo_ordinario","saltar_domingos":true,"saltar_festivos":true}');

insert into perfiles (id, tenant_id, nombre, rol)
values ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000f1', 'Admin Demo', 'admin');

insert into rutas (tenant_id, nombre) values ('00000000-0000-0000-0000-0000000000f1', 'Ruta Centro');

insert into clientes (tenant_id, ruta_id, documento, nombre, telefono, barrio, negocio, autoriza_datos)
select '00000000-0000-0000-0000-0000000000f1', r.id, v.doc, v.nombre, v.tel, v.barrio, v.negocio, true
from rutas r, (values
  ('52111222', 'Rosa Martínez',  '3001112233', 'Kennedy',  'Tienda'),
  ('80222333', 'Jairo Pérez',    '3102223344', 'Bosa',     'Frutería'),
  ('1013444555','Luisa Gómez',   '3203334455', 'Suba',     'Peluquería')
) as v(doc, nombre, tel, barrio, negocio)
where r.nombre = 'Ruta Centro';
