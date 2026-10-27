import 'dart:async';

import 'package:cobradiarios/offline/base_local.dart';
import 'package:cobradiarios/offline/sincronizador.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Map<String, dynamic> _fila(String id, {num saldo = 120000, num total = 5000}) => {
      'prestamo_id': id,
      'prestamo_numero': 1,
      'cliente_nombre': 'Rosa',
      'valor_cuota': '5000.00',
      'saldo': '$saldo',
      'cuotas_pendientes': 1,
      'mora_pendiente': '0.00',
      'total_a_cobrar_hoy': '$total',
      'dias_atraso': 0,
      'pago_hoy': false,
    };

PagosPendientesCompanion _pago(String id, String prestamo, int valor) => PagosPendientesCompanion.insert(
      id: id,
      prestamoId: prestamo,
      clienteNombre: 'Rosa',
      valor: valor,
      metodo: 'efectivo',
      fecha: DateTime(2026, 10, 27, 9),
      estado: EstadoEnvio.pendiente,
    );

void main() {
  late BaseLocal db;
  setUp(() => db = BaseLocal(NativeDatabase.memory()));
  tearDown(() => db.close());

  test('encolar un pago descuenta en la copia local', () async {
    await db.reemplazarCobros([cobroDesdeServidor(_fila('p1'), DateTime.now())]);
    await db.encolarPago(_pago('a', 'p1', 5000));

    final c = (await db.verCobros().first).single;
    expect(c.saldo, 115000);
    expect(c.totalACobrarHoy, 0);
    expect(c.pagoHoy, isTrue);
    expect(await db.cantidadPorEnviar(), 1);
  });

  test('al descargar la ruta se reaplican solo los pagos no enviados', () async {
    await db.reemplazarCobros([cobroDesdeServidor(_fila('p1'), DateTime.now())]);
    await db.encolarPago(_pago('a', 'p1', 5000));
    await db.encolarPago(_pago('b', 'p1', 2000));
    await db.marcarEnviado('a', 115000);

    // El servidor ya refleja el pago "a" (saldo 115.000) pero no el "b"
    await db.reemplazarCobros([cobroDesdeServidor(_fila('p1', saldo: 115000, total: 0), DateTime.now())]);
    expect((await db.verCobros().first).single.saldo, 113000);
    expect((await db.pagosPorEnviar()).map((p) => p.id), ['b']);
  });

  test('rechazado sale de la cola y guarda el motivo', () async {
    await db.encolarPago(_pago('a', 'p1', 5000));
    await db.marcarRechazado('a', 'La caja de hoy ya fue cerrada');
    expect(await db.cantidadPorEnviar(), 0);
    expect((await db.verPagos().first).single.error, contains('cerrada'));
  });

  test('borrarTodo limpia los datos del cobrador', () async {
    await db.reemplazarCobros([cobroDesdeServidor(_fila('p1'), DateTime.now())]);
    await db.encolarPago(_pago('a', 'p1', 5000));
    await db.borrarTodo();
    expect(await db.verCobros().first, isEmpty);
    expect(await db.verPagos().first, isEmpty);
  });

  group('clasificación de errores', () {
    test('errores de negocio de Postgres son definitivos', () {
      expect(esRechazoDefinitivo(PostgrestException(message: 'caja cerrada', code: 'P0001')), isTrue);
      expect(esRechazoDefinitivo(PostgrestException(message: 'no autorizado', code: '42501')), isTrue);
    });

    test('red, token y conexión se reintentan', () {
      expect(esRechazoDefinitivo(TimeoutException('lento')), isFalse);
      expect(esRechazoDefinitivo(Exception('SocketException')), isFalse);
      expect(esRechazoDefinitivo(PostgrestException(message: 'JWT expired', code: 'PGRST301')), isFalse);
      expect(esRechazoDefinitivo(PostgrestException(message: 'conexión', code: '08006')), isFalse);
      expect(esRechazoDefinitivo(PostgrestException(message: 'sin código')), isFalse);
    });
  });
}
