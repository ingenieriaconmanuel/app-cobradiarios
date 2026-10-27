import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

part 'base_local.g.dart';

/// Copia local de la ruta del día (vista v_cobros_del_dia) para cobrar sin señal.
/// Montos en pesos enteros: el servidor sigue siendo la fuente de verdad.
@DataClassName('CobroLocal')
class CobrosLocales extends Table {
  TextColumn get prestamoId => text()();
  IntColumn get prestamoNumero => integer()();
  TextColumn get clienteNombre => text()();
  TextColumn get telefono => text().nullable()();
  TextColumn get direccion => text().nullable()();
  TextColumn get barrio => text().nullable()();
  RealColumn get lat => real().nullable()();
  RealColumn get lng => real().nullable()();
  IntColumn get valorCuota => integer()();
  IntColumn get saldo => integer()();
  IntColumn get cuotasPendientes => integer()();
  IntColumn get moraPendiente => integer()();
  IntColumn get totalACobrarHoy => integer()();
  IntColumn get diasAtraso => integer()();
  BoolColumn get pagoHoy => boolean()();
  DateTimeColumn get descargadoEn => dateTime()();

  @override
  Set<Column> get primaryKey => {prestamoId};
}

enum EstadoEnvio { pendiente, enviado, rechazado }

/// Cola de pagos. El id (UUID v4) se genera en el teléfono y es el p_id del servidor,
/// así un reintento nunca duplica el pago.
@DataClassName('PagoPendiente')
class PagosPendientes extends Table {
  TextColumn get id => text()();
  TextColumn get prestamoId => text()();
  TextColumn get clienteNombre => text()();
  IntColumn get valor => integer()();
  TextColumn get metodo => text()();
  DateTimeColumn get fecha => dateTime()();
  RealColumn get lat => real().nullable()();
  RealColumn get lng => real().nullable()();
  IntColumn get estado => intEnum<EstadoEnvio>()();
  IntColumn get intentos => integer().withDefault(const Constant(0))();
  TextColumn get error => text().nullable()();
  IntColumn get saldoServidor => integer().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

@DriftDatabase(tables: [CobrosLocales, PagosPendientes])
class BaseLocal extends _$BaseLocal {
  BaseLocal([QueryExecutor? executor]) : super(executor ?? driftDatabase(name: 'cobradiarios'));

  @override
  int get schemaVersion => 1;

  // ---------- Lecturas ----------
  Stream<List<CobroLocal>> verCobros() =>
      (select(cobrosLocales)..orderBy([(c) => OrderingTerm.desc(c.diasAtraso), (c) => OrderingTerm.asc(c.clienteNombre)])).watch();

  Stream<List<PagoPendiente>> verPagos() =>
      (select(pagosPendientes)..orderBy([(p) => OrderingTerm.desc(p.fecha)])).watch();

  Stream<int> verCantidadPorEnviar() {
    final n = pagosPendientes.id.count();
    return (selectOnly(pagosPendientes)
          ..addColumns([n])
          ..where(pagosPendientes.estado.equalsValue(EstadoEnvio.pendiente)))
        .map((r) => r.read(n)!)
        .watchSingle();
  }

  Future<List<PagoPendiente>> pagosPorEnviar() => (select(pagosPendientes)
        ..where((p) => p.estado.equalsValue(EstadoEnvio.pendiente))
        ..orderBy([(p) => OrderingTerm.asc(p.fecha)]))
      .get();

  Future<int> cantidadPorEnviar() async => (await pagosPorEnviar()).length;

  // ---------- Escrituras ----------

  /// Guarda el pago en la cola y descuenta de inmediato en la copia local.
  Future<void> encolarPago(PagosPendientesCompanion pago) => transaction(() async {
        await into(pagosPendientes).insert(pago);
        await _aplicarEnCache(pago.prestamoId.value, pago.valor.value);
      });

  /// Reemplaza la ruta con lo que trae el servidor y vuelve a aplicar
  /// los pagos que aún no se han enviado.
  Future<void> reemplazarCobros(List<CobrosLocalesCompanion> filas) => transaction(() async {
        await delete(cobrosLocales).go();
        await batch((b) => b.insertAll(cobrosLocales, filas));
        for (final p in await pagosPorEnviar()) {
          await _aplicarEnCache(p.prestamoId, p.valor);
        }
      });

  Future<void> _aplicarEnCache(String prestamoId, int valor) => customUpdate(
        'UPDATE cobros_locales SET saldo = max(0, saldo - ?), '
        'total_a_cobrar_hoy = max(0, total_a_cobrar_hoy - ?), pago_hoy = 1 WHERE prestamo_id = ?',
        variables: [Variable.withInt(valor), Variable.withInt(valor), Variable.withString(prestamoId)],
        updates: {cobrosLocales},
      );

  Future<void> marcarEnviado(String id, int? saldoServidor) =>
      (update(pagosPendientes)..where((p) => p.id.equals(id))).write(PagosPendientesCompanion(
        estado: const Value(EstadoEnvio.enviado),
        error: const Value(null),
        saldoServidor: Value(saldoServidor),
      ));

  Future<void> marcarRechazado(String id, String error) =>
      (update(pagosPendientes)..where((p) => p.id.equals(id))).write(PagosPendientesCompanion(
        estado: const Value(EstadoEnvio.rechazado),
        error: Value(error),
      ));

  Future<void> registrarIntentoFallido(String id, String error) => customUpdate(
        'UPDATE pagos_pendientes SET intentos = intentos + 1, error = ? WHERE id = ?',
        variables: [Variable.withString(error), Variable.withString(id)],
        updates: {pagosPendientes},
      );

  Future<void> descartarPago(String id) => (delete(pagosPendientes)..where((p) => p.id.equals(id))).go();

  /// Historial: conserva los pagos enviados 7 días como comprobante del cobrador.
  Future<void> limpiarEnviadosAntiguos() => (delete(pagosPendientes)
        ..where((p) =>
            p.estado.equalsValue(EstadoEnvio.enviado) &
            p.fecha.isSmallerThanValue(DateTime.now().subtract(const Duration(days: 7)))))
      .go();

  /// Al cerrar sesión: no dejar datos de clientes en el teléfono.
  Future<void> borrarTodo() => transaction(() async {
        await delete(cobrosLocales).go();
        await delete(pagosPendientes).go();
      });
}

int _entero(Object? v) => v is num ? v.round() : (num.tryParse('$v') ?? 0).round();
double? _real(Object? v) => v == null ? null : (v is num ? v.toDouble() : double.tryParse('$v'));

/// Fila de v_cobros_del_dia (servidor) → fila local.
CobrosLocalesCompanion cobroDesdeServidor(Map<String, dynamic> f, DateTime ahora) => CobrosLocalesCompanion.insert(
      prestamoId: f['prestamo_id'] as String,
      prestamoNumero: _entero(f['prestamo_numero']),
      clienteNombre: f['cliente_nombre'] as String,
      telefono: Value(f['telefono'] as String?),
      direccion: Value(f['direccion'] as String?),
      barrio: Value(f['barrio'] as String?),
      lat: Value(_real(f['lat'])),
      lng: Value(_real(f['lng'])),
      valorCuota: _entero(f['valor_cuota']),
      saldo: _entero(f['saldo']),
      cuotasPendientes: _entero(f['cuotas_pendientes']),
      moraPendiente: _entero(f['mora_pendiente']),
      totalACobrarHoy: _entero(f['total_a_cobrar_hoy']),
      diasAtraso: _entero(f['dias_atraso']),
      pagoHoy: f['pago_hoy'] == true,
      descargadoEn: ahora,
    );

/// Misma conversión pero a objeto (para la versión web, que trabaja en línea).
CobroLocal cobroLocalDesdeServidor(Map<String, dynamic> f) {
  final c = cobroDesdeServidor(f, DateTime.now());
  return CobroLocal(
    prestamoId: c.prestamoId.value,
    prestamoNumero: c.prestamoNumero.value,
    clienteNombre: c.clienteNombre.value,
    telefono: c.telefono.value,
    direccion: c.direccion.value,
    barrio: c.barrio.value,
    lat: c.lat.value,
    lng: c.lng.value,
    valorCuota: c.valorCuota.value,
    saldo: c.saldo.value,
    cuotasPendientes: c.cuotasPendientes.value,
    moraPendiente: c.moraPendiente.value,
    totalACobrarHoy: c.totalACobrarHoy.value,
    diasAtraso: c.diasAtraso.value,
    pagoHoy: c.pagoHoy.value,
    descargadoEn: c.descargadoEn.value,
  );
}
