import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../data/sesion.dart';
import 'base_local.dart';

/// El offline solo aplica en Android/iOS. En web el cobrador trabaja en línea.
const offlineDisponible = !kIsWeb;

/// Decide si un error del servidor es definitivo (el pago nunca va a entrar
/// tal cual: caja cerrada, préstamo pagado, supera la deuda…) o transitorio
/// (sin red, token vencido, servidor caído) y hay que reintentar.
bool esRechazoDefinitivo(Object error) {
  if (error is! PostgrestException) return false;
  final codigo = error.code ?? '';
  // SQLSTATE de 5 caracteres. Excluir conexión (08), recursos (53), operador (57).
  final esSqlState = RegExp(r'^[0-9A-Z]{5}$').hasMatch(codigo) && !codigo.startsWith('PGRST');
  return esSqlState && !['08', '53', '57'].any(codigo.startsWith);
}

/// Envía la cola de pagos y descarga la ruta. Se dispara al abrir la app,
/// al recuperar señal, cada 2 minutos y con el botón de sincronizar.
class Sincronizador extends ChangeNotifier {
  Sincronizador(this._db, this._local);

  final SupabaseClient _db;
  final BaseLocal _local;
  StreamSubscription<List<ConnectivityResult>>? _red;
  Timer? _timer;
  Future<void>? _enCurso;

  bool enLinea = true;
  bool sincronizando = false;
  DateTime? ultimaSincronizacion;
  String? ultimoError;

  static const _limiteEspera = Duration(seconds: 20);

  void iniciar() {
    _red = Connectivity().onConnectivityChanged.listen((r) {
      final hayRed = r.any((x) => x != ConnectivityResult.none);
      if (hayRed && !enLinea) sincronizar();
      if (!hayRed && enLinea) {
        enLinea = false;
        notifyListeners();
      }
    });
    _timer = Timer.periodic(const Duration(minutes: 2), (_) => sincronizar());
    sincronizar();
  }

  /// Registra un pago localmente (siempre funciona, con o sin señal) y trata de enviarlo.
  Future<void> registrarPago({required String prestamoId, required String clienteNombre, required int valor, required String metodo}) async {
    await _local.encolarPago(PagosPendientesCompanion.insert(
      id: const Uuid().v4(),
      prestamoId: prestamoId,
      clienteNombre: clienteNombre,
      valor: valor,
      metodo: metodo,
      fecha: DateTime.now(),
      estado: EstadoEnvio.pendiente,
    ));
    unawaited(sincronizar(descargar: false));
  }

  /// Una sola sincronización a la vez; las llamadas concurrentes esperan la misma.
  Future<void> sincronizar({bool descargar = true}) => _enCurso ??= _sincronizar(descargar).whenComplete(() => _enCurso = null);

  Future<void> _sincronizar(bool descargar) async {
    if (_db.auth.currentUser == null) return;
    sincronizando = true;
    notifyListeners();
    try {
      final todoEnviado = await _enviarPendientes();
      if (descargar && todoEnviado) await _descargarRuta();
      await _local.limpiarEnviadosAntiguos();
      enLinea = true;
      ultimoError = null;
      ultimaSincronizacion = DateTime.now();
    } catch (e) {
      enLinea = false;
      ultimoError = e.toString();
    } finally {
      sincronizando = false;
      notifyListeners();
    }
  }

  /// Devuelve true si la cola quedó vacía. Ante un error transitorio se detiene
  /// (y relanza) para conservar el orden de los pagos.
  Future<bool> _enviarPendientes() async {
    for (final p in await _local.pagosPorEnviar()) {
      try {
        final r = await _db.rpc('registrar_pago', params: {
          'p_id': p.id,
          'p_prestamo_id': p.prestamoId,
          'p_valor': p.valor,
          'p_metodo': p.metodo,
          'p_fecha': p.fecha.toUtc().toIso8601String(),
          'p_lat': p.lat,
          'p_lng': p.lng,
        }).timeout(_limiteEspera) as Map;
        final saldo = r['saldo'];
        await _local.marcarEnviado(p.id, saldo is num ? saldo.round() : null);
      } catch (e) {
        if (esRechazoDefinitivo(e)) {
          await _local.marcarRechazado(p.id, (e as PostgrestException).message);
        } else {
          await _local.registrarIntentoFallido(p.id, e.toString());
          rethrow;
        }
      }
    }
    return await _local.cantidadPorEnviar() == 0;
  }

  Future<void> _descargarRuta() async {
    final filas = await _db.from('v_cobros_del_dia').select().timeout(_limiteEspera);
    final ahora = DateTime.now();
    await _local.reemplazarCobros([for (final f in filas) cobroDesdeServidor(f, ahora)]);
  }

  @override
  void dispose() {
    _red?.cancel();
    _timer?.cancel();
    super.dispose();
  }
}

final baseLocalProvider = Provider<BaseLocal>((ref) {
  final db = BaseLocal();
  ref.onDispose(db.close);
  return db;
});

final sincronizadorProvider = ChangeNotifierProvider<Sincronizador>((ref) {
  final s = Sincronizador(ref.watch(dbProvider), ref.watch(baseLocalProvider));
  if (offlineDisponible) s.iniciar();
  return s;
});

final cobrosLocalesProvider = StreamProvider<List<CobroLocal>>((ref) => ref.watch(baseLocalProvider).verCobros());
final pagosLocalesProvider = StreamProvider<List<PagoPendiente>>((ref) => ref.watch(baseLocalProvider).verPagos());
final porEnviarProvider = StreamProvider<int>((ref) => ref.watch(baseLocalProvider).verCantidadPorEnviar());
