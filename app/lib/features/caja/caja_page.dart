import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/formato.dart';
import '../../data/repositorio.dart';
import '../../data/sesion.dart';
import '../../offline/sincronizador.dart';

final _cajaProvider = FutureProvider.autoDispose((ref) {
  final hoy = DateFormat('yyyy-MM-dd').format(DateTime.now());
  return ref.watch(repoProvider).cajaDeHoy(ref.watch(perfilProvider).id, hoy);
});

/// Caja del día del usuario: base + cobros − desembolsos − gastos = efectivo esperado.
class CajaPage extends ConsumerWidget {
  const CajaPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final caja = ref.watch(_cajaProvider);
    return caja.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text(mensajeError(e))),
      data: (c) {
        final movs = (c?['movimientos'] as List?) ?? const [];
        num suma(Set<String> tipos) => movs.where((m) => tipos.contains(m['tipo'])).fold<num>(0, (a, m) => a + aNum(m['valor']));
        final cerrada = c?['estado'] == 'cerrada';
        final filas = [
          ('Base', suma({'base'})),
          ('Cobrado', suma({'cobro', 'anulacion'})),
          ('Prestado', suma({'desembolso'})),
          ('Gastos', suma({'gasto'})),
        ];
        final esperado = filas.fold<num>(0, (a, f) => a + f.$2);

        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(cerrada ? 'Caja cerrada' : 'Caja de hoy', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            Card(
              child: Column(children: [
                for (final (t, v) in filas) ListTile(title: Text(t), trailing: Text(pesos(v))),
                const Divider(height: 1),
                ListTile(
                  title: const Text('Efectivo esperado', style: TextStyle(fontWeight: FontWeight.bold)),
                  trailing: Text(pesos(esperado), style: Theme.of(context).textTheme.titleMedium),
                ),
                if (cerrada) ListTile(title: const Text('Diferencia al cierre'), trailing: Text(pesos(c?['diferencia']))),
              ]),
            ),
            const SizedBox(height: 16),
            if (!cerrada)
              Wrap(spacing: 12, children: [
                OutlinedButton.icon(
                  onPressed: () => _gasto(context, ref),
                  icon: const Icon(Icons.receipt_outlined),
                  label: const Text('Registrar gasto'),
                ),
                if (c != null)
                  FilledButton.icon(
                    onPressed: () => _cerrar(context, ref, c['id'] as String, esperado),
                    icon: const Icon(Icons.lock_outline),
                    label: const Text('Cerrar caja'),
                  ),
              ]),
          ],
        );
      },
    );
  }

  Future<num?> _pedirValor(BuildContext context, String titulo, {num? inicial, TextEditingController? textoConcepto}) {
    final valor = TextEditingController(text: inicial?.toStringAsFixed(0) ?? '');
    return showDialog<num>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(titulo),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          if (textoConcepto != null) ...[
            TextField(controller: textoConcepto, decoration: const InputDecoration(labelText: 'Concepto')),
            const SizedBox(height: 12),
          ],
          TextField(
            controller: valor,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(labelText: 'Valor', prefixText: r'$ '),
          ),
        ]),
        actions: [FilledButton(onPressed: () => Navigator.pop(ctx, num.tryParse(valor.text)), child: const Text('Aceptar'))],
      ),
    );
  }

  Future<void> _gasto(BuildContext context, WidgetRef ref) async {
    final concepto = TextEditingController();
    final v = await _pedirValor(context, 'Nuevo gasto', textoConcepto: concepto);
    if (v == null || concepto.text.trim().isEmpty) return;
    await _correr(context, ref, () => ref.read(repoProvider).registrarGasto(concepto.text.trim(), v));
  }

  Future<void> _cerrar(BuildContext context, WidgetRef ref, String cajaId, num esperado) async {
    // Con pagos sin enviar, el cierre quedaría descuadrado y esos pagos serían rechazados
    if (offlineDisponible) {
      await ref.read(sincronizadorProvider).sincronizar(descargar: false);
      final porEnviar = await ref.read(baseLocalProvider).cantidadPorEnviar();
      if (porEnviar > 0) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Hay $porEnviar pago(s) sin enviar. Busque señal y sincronice antes de cerrar la caja.'),
          ));
        }
        return;
      }
      ref.invalidate(_cajaProvider);
      if (!context.mounted) return;
    }
    final v = await _pedirValor(context, 'Efectivo que entrega', inicial: esperado);
    if (v == null || !context.mounted) return;
    await _correr(context, ref, () => ref.read(repoProvider).cerrarCaja(cajaId, v));
  }

  Future<void> _correr(BuildContext context, WidgetRef ref, Future<void> Function() accion) async {
    try {
      await accion();
      ref.invalidate(_cajaProvider);
    } catch (e) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(mensajeError(e))));
    }
  }
}
