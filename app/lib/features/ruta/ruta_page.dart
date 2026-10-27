import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/formato.dart';
import '../../data/repositorio.dart';
import '../../offline/base_local.dart';
import '../../offline/sincronizador.dart';

/// Web: consulta directa al servidor. Móvil: copia local que mantiene el sincronizador.
final _cobrosWebProvider = FutureProvider.autoDispose(
  (ref) async => [for (final f in await ref.watch(repoProvider).cobrosDelDia()) cobroLocalDesdeServidor(f)],
);

final cobrosDelDiaProvider = Provider.autoDispose<AsyncValue<List<CobroLocal>>>(
  (ref) => offlineDisponible ? ref.watch(cobrosLocalesProvider) : ref.watch(_cobrosWebProvider),
);

/// Pantalla principal del cobrador: a quién cobrarle hoy.
class RutaPage extends ConsumerWidget {
  const RutaPage({super.key});

  Future<void> _refrescar(WidgetRef ref) async {
    if (offlineDisponible) {
      await ref.read(sincronizadorProvider).sincronizar();
    } else {
      ref.invalidate(_cobrosWebProvider);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cobros = ref.watch(cobrosDelDiaProvider);
    return RefreshIndicator(
      onRefresh: () => _refrescar(ref),
      child: cobros.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text(mensajeError(e))),
        data: (lista) {
          final pendientes = lista.where((c) => !c.pagoHoy).length;
          final total = lista.fold<int>(0, (a, c) => a + c.totalACobrarHoy);
          return ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.only(bottom: 24),
            children: [
              if (offlineDisponible) const _BarraSincronizacion(),
              ListTile(
                title: Text('$pendientes de ${lista.length} clientes por visitar'),
                subtitle: Text('Por cobrar hoy: ${pesos(total)}'),
              ),
              const Divider(height: 1),
              if (lista.isEmpty)
                const Padding(padding: EdgeInsets.all(48), child: Center(child: Text('No hay cobros pendientes. Deslice hacia abajo para actualizar.'))),
              for (final c in lista) _TarjetaCobro(c),
            ],
          );
        },
      ),
    );
  }
}

/// Estado de la conexión y de la cola de pagos.
class _BarraSincronizacion extends ConsumerWidget {
  const _BarraSincronizacion();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sync = ref.watch(sincronizadorProvider);
    final porEnviar = ref.watch(porEnviarProvider).valueOrNull ?? 0;
    final rechazados = (ref.watch(pagosLocalesProvider).valueOrNull ?? const []).where((p) => p.estado == EstadoEnvio.rechazado).length;
    final esquema = Theme.of(context).colorScheme;
    final hora = sync.ultimaSincronizacion == null ? 'nunca' : DateFormat.Hm().format(sync.ultimaSincronizacion!);

    final (color, icono, texto) = switch ((sync.enLinea, porEnviar)) {
      (false, _) => (esquema.errorContainer, Icons.cloud_off, 'Sin señal · $porEnviar pago(s) guardados en el teléfono'),
      (true, > 0) => (esquema.tertiaryContainer, Icons.cloud_upload_outlined, 'Enviando $porEnviar pago(s)…'),
      _ => (esquema.primaryContainer, Icons.cloud_done_outlined, 'Sincronizado · $hora'),
    };

    return Material(
      color: color,
      child: ListTile(
        dense: true,
        leading: sync.sincronizando ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)) : Icon(icono),
        title: Text(texto),
        subtitle: rechazados > 0 ? Text('$rechazados pago(s) rechazado(s) por el servidor — revisar') : null,
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          IconButton(tooltip: 'Pagos del teléfono', icon: const Icon(Icons.history), onPressed: () => _verPagos(context)),
          IconButton(tooltip: 'Sincronizar', icon: const Icon(Icons.sync), onPressed: sync.sincronizando ? null : () => sync.sincronizar()),
        ]),
      ),
    );
  }

  void _verPagos(BuildContext context) => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (_) => const FractionallySizedBox(heightFactor: 0.7, child: _PagosDelTelefono()),
      );
}

class _PagosDelTelefono extends ConsumerWidget {
  const _PagosDelTelefono();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pagos = ref.watch(pagosLocalesProvider).valueOrNull ?? const [];
    if (pagos.isEmpty) return const Center(child: Text('No hay pagos registrados en este teléfono'));
    return ListView(children: [
      const ListTile(title: Text('Pagos registrados en este teléfono')),
      for (final p in pagos)
        ListTile(
          leading: Icon(switch (p.estado) {
            EstadoEnvio.enviado => Icons.cloud_done,
            EstadoEnvio.pendiente => Icons.schedule,
            EstadoEnvio.rechazado => Icons.error_outline,
          }),
          title: Text('${p.clienteNombre} · ${pesos(p.valor)}'),
          subtitle: Text([
            DateFormat('d MMM HH:mm', 'es_CO').format(p.fecha),
            p.metodo,
            if (p.estado == EstadoEnvio.rechazado && p.error != null) p.error!,
            if (p.estado == EstadoEnvio.pendiente && p.intentos > 0) '${p.intentos} intento(s)',
          ].join(' · ')),
          trailing: p.estado == EstadoEnvio.rechazado
              ? IconButton(
                  tooltip: 'Descartar (avise al supervisor)',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => ref.read(baseLocalProvider).descartarPago(p.id),
                )
              : null,
        ),
    ]);
  }
}

class _TarjetaCobro extends ConsumerWidget {
  const _TarjetaCobro(this.c);
  final CobroLocal c;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final esquema = Theme.of(context).colorScheme;
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: c.pagoHoy ? esquema.primaryContainer : (c.diasAtraso > 0 ? esquema.errorContainer : esquema.surfaceContainerHighest),
        child: Icon(c.pagoHoy ? Icons.check : Icons.person_outline),
      ),
      title: Text(c.clienteNombre),
      subtitle: Text([
        if (c.direccion != null) c.direccion!,
        'Cuota ${pesos(c.valorCuota)} · Saldo ${pesos(c.saldo)}',
        if (c.diasAtraso > 0) '${c.diasAtraso} días de atraso · mora ${pesos(c.moraPendiente)}',
      ].join('\n')),
      isThreeLine: true,
      trailing: Text(pesos(c.totalACobrarHoy), style: Theme.of(context).textTheme.titleMedium),
      onTap: () => _dialogoPago(context, ref),
    );
  }

  Future<void> _dialogoPago(BuildContext context, WidgetRef ref) async {
    final valor = TextEditingController(text: '${c.valorCuota}');
    var metodo = 'efectivo';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text('Pago de ${c.clienteNombre}'),
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
    final monto = int.tryParse(valor.text) ?? 0;
    if (ok != true || monto <= 0 || !context.mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    try {
      if (offlineDisponible) {
        await ref.read(sincronizadorProvider).registrarPago(
              prestamoId: c.prestamoId,
              clienteNombre: c.clienteNombre,
              valor: monto,
              metodo: metodo,
            );
        messenger.showSnackBar(SnackBar(content: Text('Pago de ${pesos(monto)} guardado. Se envía al tener señal.')));
      } else {
        final r = await ref.read(repoProvider).registrarPago(prestamoId: c.prestamoId, valor: monto, metodo: metodo);
        messenger.showSnackBar(SnackBar(content: Text('Pago registrado. Nuevo saldo: ${pesos(r['saldo'])}')));
        ref.invalidate(_cobrosWebProvider);
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(mensajeError(e))));
    }
  }
}
