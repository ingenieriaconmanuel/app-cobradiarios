import { PGlite } from '@electric-sql/pglite';
import fs from 'node:fs';
import path from 'node:path';

const dir = process.argv[2];
const db = new PGlite();

const stub = `
create role anon nologin; create role authenticated nologin; create role service_role nologin bypassrls;
create schema auth;
create table auth.users (id uuid primary key, email text);
create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
grant usage on schema auth to authenticated, anon;
grant execute on function auth.uid() to authenticated, anon;
grant usage on schema public to authenticated, anon;
create schema cron;
create function cron.schedule(text, text, text) returns bigint language sql as $$ select 1::bigint $$;
`;
await db.exec(stub);

for (const f of fs.readdirSync(dir).sort()) {
  let sql = fs.readFileSync(path.join(dir, f), 'utf8');
  sql = sql.replace(/create extension if not exists pg_cron;/, '').replace(/create extension if not exists pgcrypto;/, '');
  try { await db.exec(sql); console.log('OK  ', f); }
  catch (e) { console.log('FAIL', f, '\n   ', e.message); process.exit(1); }
}

const A = '00000000-0000-0000-0000-00000000000a';
const B = '00000000-0000-0000-0000-00000000000b';
const C = '00000000-0000-0000-0000-00000000000c';
await db.exec(`insert into auth.users values ('${A}','a@x.co'),('${B}','b@x.co'),('${C}','c@x.co')`);

let fails = 0;
async function as(uid, sql, params = []) {
  await db.exec(`reset role; select set_config('request.jwt.claim.sub', '${uid ?? ''}', false); set role ${uid ? 'authenticated' : 'postgres'};`);
  try { return (await db.query(sql, params)).rows; }
  finally { await db.exec('reset role'); }
}
async function check(name, fn) {
  try { const r = await fn(); console.log('PASS', name, r === undefined ? '' : JSON.stringify(r)); }
  catch (e) { fails++; console.log('FAIL', name, '->', e.message); }
}
async function expectError(name, fn, pattern) {
  try { await fn(); fails++; console.log('FAIL', name, '-> no lanzó error'); }
  catch (e) {
    if (pattern && !new RegExp(pattern, 'i').test(e.message)) { fails++; console.log('FAIL', name, '-> error inesperado:', e.message); }
    else console.log('PASS', name, '(error esperado:', e.message + ')');
  }
}
const eq = (a, b, msg) => { if (JSON.stringify(a) !== JSON.stringify(b)) throw new Error(`${msg}: esperado ${JSON.stringify(b)}, obtuvo ${JSON.stringify(a)}`); return a; };

// --- Festivos 2026
await check('festivos 2026', async () => {
  const r = await as(null, `select string_agg(to_char(fecha,'MM-DD'), ',' order by fecha) f from festivos where extract(year from fecha)=2026`);
  return eq(r[0].f, '01-01,01-12,03-23,04-02,04-03,05-01,05-18,06-08,06-15,06-29,07-20,08-07,08-17,10-12,11-02,11-16,12-08,12-25', 'festivos');
});

// --- Registro de empresas
let T1, T2;
await check('registrar empresa A', async () => { T1 = (await as(A, `select registrar_empresa('Créditos A','Ana') id`))[0].id; return T1; });
await check('registrar empresa B', async () => { T2 = (await as(B, `select registrar_empresa('Créditos B','Beto') id`))[0].id; return T2; });
await expectError('no se registra dos veces', () => as(A, `select registrar_empresa('Otra','Ana')`), 'ya pertenece');

// Cobrador C (lo crearía la edge function con service role)
await as(null, `insert into perfiles (id, tenant_id, nombre, rol) values ('${C}', '${T1}', 'Carlos', 'cobrador')`);

let R1;
await check('admin crea ruta', async () => { R1 = (await as(A, `insert into rutas (nombre) values ('Ruta Centro') returning id`))[0].id; return R1; });
await expectError('cobrador no crea rutas', () => as(C, `insert into rutas (nombre) values ('X')`), 'row-level security');
await check('asignar ruta al cobrador', () => as(A, `insert into rutas_usuarios (ruta_id, usuario_id, tenant_id) values ($1,$2,$3)`, [R1, C, T1]));

let CL1;
await check('admin crea cliente', async () => { CL1 = (await as(A, `insert into clientes (documento, nombre, ruta_id, autoriza_datos) values ('1010','Doña Rosa',$1,true) returning id`, [R1]))[0].id; });
await check('cliente sin ruta (solo admin lo ve)', () => as(A, `insert into clientes (documento, nombre) values ('2020','Sin ruta')`));
await check('cobrador ve solo su ruta', async () => eq((await as(C, `select count(*)::int n from clientes`))[0].n, 1, 'clientes cobrador'));
await check('tenant B no ve clientes de A', async () => eq((await as(B, `select count(*)::int n from clientes`))[0].n, 0, 'clientes B'));
await expectError('tenant B no inserta en tenant A', () => as(B, `insert into clientes (tenant_id, documento, nombre) values ($1,'9','Hack')`, [T1]), 'row-level security');
await expectError('cobrador no escala su rol', () => as(C, `update perfiles set rol='admin' where id=$1 returning id`, [C]).then(r => { if (!r.length) throw new Error('row-level security: 0 filas'); }), 'row-level security');
await expectError('insert directo en prestamos prohibido', () => as(A, `insert into prestamos (tenant_id) values ($1)`, [T1]), 'permission denied');

// --- Simulación
await check('simulación flat 100k 20% 24 cuotas diarias', async () => {
  const s = (await as(A, `select simular_prestamo(100000, 0.20, 24, 'diario', 'flat', '2026-12-05') s`))[0].s;
  eq(s.valor_cuota, 5000, 'cuota'); eq(s.total_a_pagar, 120000, 'total');
  const fechas = s.cuotas.map(c => c.fecha_vencimiento);
  if (fechas.some(f => new Date(f + 'T12:00:00Z').getUTCDay() === 0)) throw new Error('hay domingos');
  if (fechas.includes('2026-12-08') || fechas.includes('2026-12-25')) throw new Error('hay festivos');
  return { ea: s.tasa_ea, ultima: s.fecha_ultima_cuota, usura: s.tasa_usura_ea };
});
await check('simulación francés 1M 2% 12 meses', async () => {
  const s = (await as(A, `select simular_prestamo(1000000, 0.02, 12, 'mensual', 'frances', '2026-11-30') s`))[0].s;
  const cap = s.cuotas.reduce((a, c) => a + Number(c.capital), 0);
  eq(cap, 1000000, 'suma capital');
  return { cuota: s.valor_cuota, ea: s.tasa_ea, fechas: s.cuotas.slice(0, 4).map(c => c.fecha_vencimiento) };
});

// --- Usura
await as(null, `insert into tasas_usura values ('consumo_ordinario', '2026-10-01', '2026-10-31', 0.25), ('consumo_ordinario', '2026-11-01', '2026-11-30', 0.25)`);
await expectError('bloqueo por usura', () => as(A, `select crear_prestamo($1, 100000, 0.20, 24)`, [CL1]), 'usura');
await as(A, `update tenants set config = config || '{"politica_usura":"advertir"}' where id = $1`, [T1]);

let P1;
await check('crear préstamo (modo advertir)', async () => {
  const r = (await as(C, `select crear_prestamo($1, 100000, 0.20, 24) r`, [CL1]))[0].r;
  P1 = r.prestamo_id; eq(r.supera_usura, true, 'supera_usura'); return { cuota: r.valor_cuota, entregado: r.efectivo_entregado };
});
await check('24 cuotas generadas', async () => eq((await as(C, `select count(*)::int n from cuotas where prestamo_id=$1`, [P1]))[0].n, 24, 'cuotas'));
await check('B no ve préstamos de A', async () => eq((await as(B, `select count(*)::int n from prestamos`))[0].n, 0, 'prestamos B'));
await check('B no ve cuotas de A', async () => eq((await as(B, `select count(*)::int n from cuotas`))[0].n, 0, 'cuotas B'));

// --- Pagos
const PAGO1 = '11111111-1111-4111-8111-111111111111';
await check('pago 7.000 (cuota 1 + parcial 2)', async () => {
  const r = (await as(C, `select registrar_pago($1, $2, 7000) r`, [PAGO1, P1]))[0].r;
  eq(r.saldo, 113000, 'saldo'); return r;
});
await check('reintento offline idempotente', async () => eq((await as(C, `select registrar_pago($1, $2, 7000) r`, [PAGO1, P1]))[0].r.duplicado, true, 'duplicado'));
await check('estado de cuotas 1 y 2', async () => eq((await as(C, `select array_agg(estado::text order by numero) e from cuotas where prestamo_id=$1 and numero<=3`, [P1]))[0].e, ['pagada', 'parcial', 'pendiente'], 'estados'));
await expectError('B no cobra préstamo de A', () => as(B, `select registrar_pago(gen_random_uuid(), $1, 1000)`, [P1]), 'no encontrado');
await expectError('pago mayor a la deuda', () => as(C, `select registrar_pago(gen_random_uuid(), $1, 999999)`, [P1]), 'supera');
await expectError('cobrador no anula pagos', () => as(C, `select anular_pago($1, 'error')`, [PAGO1]), 'administradores');

// --- Mora
await as(null, `update prestamos set mora_pct_diaria = 0.01 where id = $1`, [P1]);
await as(null, `update cuotas set fecha_vencimiento = app.hoy() - 5 where prestamo_id = $1 and numero in (2,3)`, [P1]);
await check('mora calculada', async () => {
  await as(null, `select app.actualizar_mora()`);
  const r = await as(C, `select numero, estado, mora from cuotas where prestamo_id=$1 and numero in (2,3) order by numero`, [P1]);
  eq(r.map(x => Number(x.mora)), [150, 250], 'mora (3000*1%*5, 5000*1%*5)'); return r;
});
await check('ruta del día', async () => (await as(C, `select cliente_nombre, cuotas_pendientes, total_a_cobrar_hoy, dias_atraso, pago_hoy from v_cobros_del_dia`))[0]);
await check('pago 3.400 cubre mora primero', async () => (await as(C, `select registrar_pago(gen_random_uuid(), $1, 3400) r`, [P1]))[0].r);

// --- Anulación
await check('admin anula pago 1', async () => {
  await as(A, `select anular_pago($1, 'Digitado dos veces')`, [PAGO1]);
  return (await as(A, `select saldo from prestamos where id=$1`, [P1]))[0];
});

// --- Caja
await check('gasto del cobrador', () => as(C, `select registrar_gasto('Gasolina', 10000)`));
await check('admin asigna base', () => as(A, `select asignar_base($1, 200000)`, [C]));
await check('cierre de caja del cobrador', async () => {
  const caja = (await as(C, `select id from cajas where usuario_id = auth.uid()`))[0].id;
  const r = (await as(C, `select * from cerrar_caja($1, 70000)`, [caja]))[0];
  return { base: r.total_base, cobrado: r.total_cobrado, desemb: r.total_desembolsado, gastos: r.total_gastos, esperado: r.esperado, dif: r.diferencia };
});
await expectError('no cobra con caja cerrada', () => as(C, `select registrar_pago(gen_random_uuid(), $1, 1000)`, [P1]), 'cerrada');

// --- Renovación
await as(A, `update tenants set config = config || '{"politica_usura":"advertir"}' where id=$1`, [T1]);
await check('renovación descuenta saldo', async () => {
  const r = (await as(A, `select crear_prestamo($1, 200000, 0.20, 24, p_renovar_prestamo_id => $2) r`, [CL1, P1]))[0].r;
  const ant = (await as(A, `select estado, saldo from prestamos where id=$1`, [P1]))[0];
  eq(ant.estado, 'renovado', 'estado anterior'); return { entregado: r.efectivo_entregado, saldo_renovado: r.saldo_renovado };
});

// --- Límite plan
await as(null, `insert into auth.users values ('00000000-0000-0000-0000-0000000000dd','d@x.co')`);
await expectError('límite de cobradores del plan', () => as(null, `insert into perfiles (id, tenant_id, nombre, rol) values ('00000000-0000-0000-0000-0000000000dd', '${T1}', 'Dani', 'cobrador')`), 'plan permite');

// --- Suspensión
await as(null, `update tenants set estado='suspendido' where id=$1`, [T1]);
await expectError('tenant suspendido no opera', () => as(A, `select registrar_gasto('x', 1)`), 'suscripción');
await check('tenant suspendido sí lee', async () => (await as(A, `select count(*)::int n from prestamos`))[0]);

console.log(fails ? `\n${fails} FALLAS` : '\nTODO OK');
process.exit(fails ? 1 : 0);
