import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/formato.dart';
import '../../data/repositorio.dart';

final cobrosDelDiaProvider = FutureProvider.autoDispose((ref) => ref.watch(repoProvider).cobrosDelDia());

/// Pantalla principal del cobrador: a quién cobrarle hoy.
class RutaPage extends ConsumerWidget {
  const RutaPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cobros = ref.watch(cobrosDelDiaProvider);
    return RefreshIndicator(
      onRefresh: () => ref.refresh(cobrosDelDiaProvider.future),
      child: cobros.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text(mensajeError(e))),
        data: (lista) {
          if (lista.isEmpty) return ListView(children: const [SizedBox(height: 120), Center(child: Text('No hay cobros pendientes hoy'))]);
          final pendientes = lista.where((c) => c['pago_hoy'] != true).length;
          final total = lista.fold<num>(0, (a, c) => a + aNum(c['total_a_cobrar_hoy']));
          return ListView(
            padding: const EdgeInsets.only(bottom: 24),
            children: [
              ListTile(
                title: Text('$pendientes de ${lista.length} clientes por visitar'),
                subtitle: Text('Por cobrar hoy: ${pesos(total)}'),
              ),
              const Divider(height: 1),
              for (final c in lista) _TarjetaCobro(c),
            ],
          );
        },
      ),
    );
  }
}

class _TarjetaCobro extends ConsumerWidget {
  const _TarjetaCobro(this.c);
  final Fila c;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final atraso = aNum(c['dias_atraso']).toInt();
    final esquema = Theme.of(context).colorScheme;
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: c['pago_hoy'] == true ? esquema.primaryContainer : (atraso > 0 ? esquema.errorContainer : esquema.surfaceContainerHighest),
        child: Icon(c['pago_hoy'] == true ? Icons.check : Icons.person_outline),
      ),
      title: Text('${c['cliente_nombre']}'),
      subtitle: Text([
        if (c['direccion'] != null) '${c['direccion']}',
        'Cuota ${pesos(c['valor_cuota'])} · Saldo ${pesos(c['saldo'])}',
        if (atraso > 0) '$atraso días de atraso · mora ${pesos(c['mora_pendiente'])}',
      ].join('\n')),
      isThreeLine: true,
      trailing: Text(pesos(c['total_a_cobrar_hoy']), style: Theme.of(context).textTheme.titleMedium),
      onTap: () => _dialogoPago(context, ref),
    );
  }

  Future<void> _dialogoPago(BuildContext context, WidgetRef ref) async {
    final valor = TextEditingController(text: aNum(c['valor_cuota']).toStringAsFixed(0));
    var metodo = 'efectivo';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text('Pago de ${c['cliente_nombre']}'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              controller: valor,
              autofocus: true,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(labelText: 'Valor recibido', prefixText: r'$ '),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField(
              value: metodo,
              decoration: const InputDecoration(labelText: 'Método'),
              items: const [
                DropdownMenuItem(value: 'efectivo', child: Text('Efectivo')),
                DropdownMenuItem(value: 'nequi', child: Text('Nequi')),
                DropdownMenuItem(value: 'daviplata', child: Text('Daviplata')),
                DropdownMenuItem(value: 'transferencia', child: Text('Transferencia')),
              ],
              onChanged: (v) => setLocal(() => metodo = v!),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Registrar pago')),
          ],
        ),
      ),
    );
    if (ok != true || !context.mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    try {
      final r = await ref.read(repoProvider).registrarPago(
            prestamoId: c['prestamo_id'] as String,
            valor: num.parse(valor.text),
            metodo: metodo,
          );
      messenger.showSnackBar(SnackBar(content: Text('Pago registrado. Nuevo saldo: ${pesos(r['saldo'])}')));
      ref.invalidate(cobrosDelDiaProvider);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(mensajeError(e))));
    }
  }
}
