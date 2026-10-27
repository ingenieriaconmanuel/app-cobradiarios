import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import 'sesion.dart';

typedef Fila = Map<String, dynamic>;

/// Acceso a datos. Lecturas directas (filtradas por RLS) y escrituras de dinero por RPC.
class Repositorio {
  Repositorio(this._db);
  final SupabaseClient _db;

  // ---------- Lecturas ----------
  Future<Fila?> resumenCartera() => _db.from('v_resumen_cartera').select().maybeSingle();

  Future<List<Fila>> cobrosDelDia() =>
      _db.from('v_cobros_del_dia').select().order('dias_atraso', ascending: false);

  Future<List<Fila>> clientes({String? buscar}) {
    var q = _db.from('clientes').select('*, rutas(nombre)').eq('activo', true);
    if (buscar != null && buscar.isNotEmpty) q = q.or('nombre.ilike.%$buscar%,documento.ilike.%$buscar%');
    return q.order('nombre').limit(200);
  }

  Future<List<Fila>> rutas() => _db.from('rutas').select().eq('activa', true).order('nombre');

  Future<List<Fila>> prestamosActivos(String clienteId) =>
      _db.from('prestamos').select().eq('cliente_id', clienteId).eq('estado', 'activo');

  Future<Fila?> cajaDeHoy(String usuarioId, String hoy) async {
    final caja = await _db.from('cajas').select().eq('usuario_id', usuarioId).eq('fecha', hoy).maybeSingle();
    if (caja == null) return null;
    final movs = await _db.from('movimientos_caja').select('tipo, valor').eq('caja_id', caja['id']);
    return {...caja, 'movimientos': movs};
  }

  // ---------- Escrituras ----------
  Future<void> crearCliente(Fila datos) => _db.from('clientes').insert(datos);

  Future<void> crearRuta(String nombre) => _db.from('rutas').insert({'nombre': nombre});

  Future<Fila> simularPrestamo(ParamsPrestamo p) async =>
      Fila.from(await _db.rpc('simular_prestamo', params: p.aRpc()) as Map);

  Future<Fila> crearPrestamo(String clienteId, ParamsPrestamo p, {String? renovarId}) async =>
      Fila.from(await _db.rpc('crear_prestamo', params: {
        'p_cliente_id': clienteId,
        ...p.aRpc(),
        'p_mora_pct_diaria': p.moraPctDiaria,
        'p_dias_gracia': p.diasGracia,
        if (renovarId != null) 'p_renovar_prestamo_id': renovarId,
      }) as Map);

  /// El id se genera aquí para que un reintento (offline) no duplique el pago.
  Future<Fila> registrarPago({required String prestamoId, required num valor, String metodo = 'efectivo', String? id}) async =>
      Fila.from(await _db.rpc('registrar_pago', params: {
        'p_id': id ?? const Uuid().v4(),
        'p_prestamo_id': prestamoId,
        'p_valor': valor,
        'p_metodo': metodo,
        'p_fecha': DateTime.now().toUtc().toIso8601String(),
      }) as Map);

  Future<void> registrarGasto(String concepto, num valor) =>
      _db.rpc('registrar_gasto', params: {'p_concepto': concepto, 'p_valor': valor});

  Future<void> cerrarCaja(String cajaId, num efectivo) =>
      _db.rpc('cerrar_caja', params: {'p_caja_id': cajaId, 'p_efectivo_entregado': efectivo});

  Future<void> invitarUsuario(Fila datos) async {
    final r = await _db.functions.invoke('invitar-usuario', body: datos);
    if (r.status != 200) throw Exception((r.data as Map?)?['error'] ?? 'Error al crear usuario');
  }
}

class ParamsPrestamo {
  ParamsPrestamo({
    required this.capital,
    required this.tasa,
    required this.numCuotas,
    this.frecuencia = 'diario',
    this.tipoInteres = 'flat',
    this.moraPctDiaria = 0,
    this.diasGracia = 0,
  });

  num capital;
  num tasa; // flat: tasa total del plazo; frances/solo_interes: tasa por periodo
  int numCuotas;
  String frecuencia;
  String tipoInteres;
  num moraPctDiaria;
  int diasGracia;

  Fila aRpc() => {
        'p_capital': capital,
        'p_tasa': tasa,
        'p_num_cuotas': numCuotas,
        'p_frecuencia': frecuencia,
        'p_tipo_interes': tipoInteres,
      };
}

final repoProvider = Provider<Repositorio>((ref) => Repositorio(ref.watch(dbProvider)));

/// Mensaje legible de errores de Postgres / RLS.
String mensajeError(Object e) => switch (e) {
      PostgrestException(:final message) => message,
      AuthException(:final message) => message,
      _ => e.toString().replaceFirst('Exception: ', ''),
    };
