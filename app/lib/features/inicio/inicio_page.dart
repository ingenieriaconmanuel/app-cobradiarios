import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/formato.dart';
import '../../data/repositorio.dart';

final _resumenProvider = FutureProvider.autoDispose((ref) => ref.watch(repoProvider).resumenCartera());

class InicioPage extends ConsumerWidget {
  const InicioPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final resumen = ref.watch(_resumenProvider);
    return RefreshIndicator(
      onRefresh: () => ref.refresh(_resumenProvider.future),
      child: resumen.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text(mensajeError(e))),
        data: (r) {
          final tarjetas = [
            ('Cartera', pesos(r?['cartera']), Icons.account_balance_wallet_outlined),
            ('Capital colocado', pesos(r?['capital_colocado']), Icons.trending_up),
            ('Cartera vencida', pesos(r?['cartera_vencida']), Icons.warning_amber_outlined),
            ('Recaudo de hoy', pesos(r?['recaudo_hoy']), Icons.payments_outlined),
            ('Préstamos activos', '${r?['prestamos_activos'] ?? 0}', Icons.receipt_long_outlined),
          ];
          return GridView.extent(
            maxCrossAxisExtent: 280,
            childAspectRatio: 1.8,
            padding: const EdgeInsets.all(16),
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            children: [
              for (final (titulo, valor, icono) in tarjetas)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(children: [Icon(icono, size: 18), const SizedBox(width: 6), Text(titulo)]),
                        Text(valor, style: Theme.of(context).textTheme.headlineSmall),
                      ],
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
