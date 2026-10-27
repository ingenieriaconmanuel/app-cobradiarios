# CobraDiarios

SaaS multitenant de préstamos y cobro diario. Flutter (web + Android) + Supabase (PostgreSQL con Row Level Security, una sola base de datos).

## Estructura

```
app-cobradiarios/
├─ app/                         Flutter (web para admin/supervisor, Android para cobradores)
│  └─ lib/
│     ├─ core/                  env, router (redirección por sesión y rol), tema, formato COP
│     ├─ data/                  sesion.dart (perfil/rol), repositorio.dart (lecturas + RPC)
│     ├─ offline/               drift (base local) + sincronizador de pagos
│     └─ features/              auth, shell, inicio, ruta, clientes, prestamos, caja, usuarios
├─ supabase/
│  ├─ migrations/               01 multitenant · 02 cartera · 03 caja · 04 festivos/usura
│  │                            05 lógica de negocio · 06 RLS y vistas · 07 pg_cron
│  ├─ functions/invitar-usuario Edge Function: el admin crea usuarios de su empresa
│  ├─ tests/pglite/             40 pruebas SQL sin Docker (aislamiento, pagos, mora, caja…)
│  └─ seed.sql                  datos demo locales (admin@demo.test / Demo12345)
└─ .github/workflows/ci.yml     pruebas en PR · main → staging · tag v* → producción
```

## Reglas de diseño

| Regla | Dónde |
|---|---|
| Cada tabla de negocio tiene `tenant_id` y RLS. El tenant sale de `perfiles`, nunca del cliente. | `app.tenant_id()` |
| El cobrador solo ve clientes, préstamos y cuotas de sus rutas. | `app.puede_ver_ruta()` |
| Las tablas de dinero son de solo lectura para la app; se escriben solo por RPC. | migración 06 |
| Los pagos llevan un UUID generado en el teléfono → reintentos offline sin duplicados. | `registrar_pago` |
| El pago se aplica primero a la mora y luego a las cuotas, de la más antigua a la más nueva. | `registrar_pago` |
| Los pagos no se borran: se anulan con motivo (solo admin/supervisor) y queda auditoría. | `anular_pago` |
| Fechas de cobro sin domingos ni festivos de Colombia (Ley Emiliani, calculados 2025–2040). | migración 04 |
| Tasa E.A. calculada (TIR) contra la tasa de usura vigente: `bloquear` o `advertir` por tenant. | `simular_prestamo` |
| Límites del plan (cobradores, clientes) validados en la base de datos. | triggers |
| Tenant suspendido: puede leer, no puede escribir. | `app.exigir_operativo()` |

### Tipos de préstamo

| `tipo_interes` | Significado de `tasa` | Ejemplo |
|---|---|---|
| `flat` | tasa **total** sobre el capital por todo el plazo | 100.000 al 20 % en 24 cuotas diarias = 24 × 5.000 |
| `frances` | tasa **por periodo**, cuota fija con amortización | 1.000.000 al 2 % mensual × 12 = 94.560 |
| `solo_interes` | tasa **por periodo**, capital al final | |

Frecuencias: `diario`, `semanal`, `quincenal`, `mensual`.

## Requisitos (Windows)

1. **Flutter**: https://docs.flutter.dev/get-started/install/windows (agregar `flutter\bin` al PATH).
2. **Docker Desktop** (para Supabase local).
3. **Supabase CLI**: se usa con `npx supabase …` (Node ya está instalado).
4. **Git** + repositorio en GitHub.

> ⚠️ Esta carpeta está en Google Drive. Drive sincroniza `.git`, `build/` y `.dart_tool/` y puede corromperlos.
> Recomendado: clonar el repositorio en una carpeta local (ej. `C:\dev\app-cobradiarios`) y usar GitHub como respaldo.

## Desarrollo local

```bash
npx supabase init            # solo la primera vez: crea supabase/config.toml (no toca migrations)
npx supabase start           # levanta Postgres, Auth, Studio en Docker
npx supabase db reset        # aplica migraciones + seed.sql
npx supabase functions serve invitar-usuario
```

Copiar `.env.example` a `.env` con la URL y anon key que muestra `supabase start`, y luego:

```bash
cd app
flutter create . --platforms=web,android --org co.cobradiarios   # solo la primera vez: genera android/ y web/
flutter pub get
dart run build_runner build --delete-conflicting-outputs   # genera lib/offline/base_local.g.dart (drift)
flutter run -d chrome --dart-define-from-file=../.env      # web (en línea)
flutter run -d android --dart-define-from-file=../.env     # cobrador con modo offline
```

## Modo offline del cobrador (Android)

```
 Cobrador toca "Registrar pago"
        │
        ▼
 drift (SQLite en el teléfono) ── cola pagos_pendientes (UUID v4 = p_id)
        │                         + descuento inmediato en cobros_locales
        ▼
 Sincronizador: al abrir la app, al volver la señal, cada 2 min o con el botón
        │
        ├─ envía la cola en orden → registrar_pago (idempotente por p_id)
        │     ├─ OK / duplicado          → enviado (se guarda 7 días como historial)
        │     ├─ error de negocio (SQL)  → rechazado con el motivo, el cobrador lo ve
        │     └─ sin red / token / 5xx   → se queda pendiente y se reintenta
        └─ si la cola quedó vacía → descarga v_cobros_del_dia y reaplica lo pendiente
```

- `lib/offline/base_local.dart`: tablas locales `cobros_locales` y `pagos_pendientes`.
- `lib/offline/sincronizador.dart`: envío, reintentos, descarga y `esRechazoDefinitivo()`.
- El perfil queda guardado en el teléfono: la app abre sin señal si ya se había ingresado antes.
- No se puede **cerrar caja** ni **cerrar sesión** con pagos sin enviar. Al cerrar sesión se borran los datos locales.
- En web no hay modo offline: el cobrador trabaja directamente contra el servidor.
- La pantalla de caja, los clientes y la creación de préstamos siguen requiriendo conexión.

### Pruebas

```bash
cd supabase/tests/pglite && npm install && npm test   # SQL, sin Docker
cd app && flutter test   # en Windows, las pruebas de drift necesitan sqlite3.dll en el PATH
```

## Despliegue

1. Crear 2 proyectos en supabase.com: `cobradiarios-staging` (Free) y `cobradiarios-prod` (Pro, región São Paulo).
2. En cada proyecto: Database → Extensions → habilitar **pg_cron**.
3. `npx supabase link --project-ref <ref>` y `npx supabase db push`, luego `npx supabase functions deploy invitar-usuario`.
4. Auth → URL Configuration: poner el dominio de la app (ej. `https://app.tudominio.com`).
5. Cloudflare Pages: crear proyecto, dominio `app.tudominio.com`.
6. GitHub → Settings → Environments `staging` y `produccion` con los secretos:
   `SUPABASE_ACCESS_TOKEN`, `SUPABASE_DB_PASSWORD`, `SUPABASE_PROJECT_REF`, `SUPABASE_URL`, `SUPABASE_ANON_KEY`,
   `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID`, y la variable `CLOUDFLARE_PROJECT`.
7. `git push` a `main` → staging. `git tag v0.1.0 && git push --tags` → producción.
8. Android: `flutter build appbundle --release` → Google Play Console (prueba interna primero).

## Operación mensual

- **Tasa de usura**: cargar cada mes la certificada por la Superfinanciera:
  ```sql
  insert into tasas_usura values ('consumo_ordinario', '2026-11-01', '2026-11-30', 0.XXXX);
  ```
  Sin registro vigente, la validación de usura no se aplica.
- **Activar un tenant que pagó**: insertar en `suscripciones` y `update tenants set estado = 'activo'`.
  (Fase 3: webhook de Wompi lo hace automático.)

## Próximas fases

- [x] Modo offline del cobrador (drift/SQLite + cola de pagos)
- [ ] Gastos y gestiones de cobro offline (requiere id generado en el teléfono en `registrar_gasto`)
- [ ] GPS y foto en pagos y clientes, recibo por WhatsApp / impresora Bluetooth
- [ ] Panel superadmin + suscripciones con Wompi (webhook)
- [ ] Reportes: recaudo vs meta, mora por rangos 1–30/31–60/+60, utilidad, exportar Excel
- [ ] Gestiones de cobro y promesas de pago en la UI (la tabla ya existe)
