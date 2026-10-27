import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/repositorio.dart';
import '../../data/sesion.dart';

final _buscarProvider = StateProvider.autoDispose<String>((_) => '');
final _clientesProvider = FutureProvider.autoDispose(
  (ref) => ref.watch(repoProvider).clientes(buscar: ref.watch(_buscarProvider)),
);
final rutasProvider = FutureProvider.autoDispose((ref) => ref.watch(repoProvider).rutas());

class ClientesPage extends ConsumerWidget {
  const ClientesPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final clientes = ref.watch(_clientesProvider);
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _nuevoCliente(context, ref),
        icon: const Icon(Icons.person_add_alt),
        label: const Text('Cliente'),
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: TextField(
            decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Buscar por nombre o documento'),
            onSubmitted: (v) => ref.read(_buscarProvider.notifier).state = v.trim(),
          ),
        ),
        Expanded(
          child: clientes.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(child: Text(mensajeError(e))),
            data: (lista) => ListView.separated(
              itemCount: lista.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) {
                final c = lista[i];
                return ListTile(
                  title: Text('${c['nombre']}'),
                  subtitle: Text('CC ${c['documento']} · ${c['telefono'] ?? ''} · ${(c['rutas'] as Map?)?['nombre'] ?? 'Sin ruta'}'),
                  trailing: FilledButton.tonalIcon(
                    onPressed: () => context.go('/prestamos/nuevo', extra: c),
                    icon: const Icon(Icons.add_card),
                    label: const Text('Prestar'),
                  ),
                );
              },
            ),
          ),
        ),
      ]),
    );
  }

  Future<void> _nuevoCliente(BuildContext context, WidgetRef ref) async {
    final campos = {
      'documento': TextEditingController(),
      'nombre': TextEditingController(),
      'telefono': TextEditingController(),
      'direccion': TextEditingController(),
      'barrio': TextEditingController(),
      'negocio': TextEditingController(),
    };
    final rutas = await ref.read(rutasProvider.future);
    final perfil = ref.read(perfilProvider);
    String? rutaId = rutas.length == 1 ? rutas.first['id'] as String : null;
    var autoriza = false;
    if (!context.mounted) return;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Nuevo cliente'),
          content: SizedBox(
            width: 420,
            child: ListView(shrinkWrap: true, children: [
              for (final e in campos.entries)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: TextField(controller: e.value, decoration: InputDecoration(labelText: e.key[0].toUpperCase() + e.key.substring(1))),
                ),
              DropdownButtonFormField<String>(
                value: rutaId,
                decoration: const InputDecoration(labelText: 'Ruta'),
                items: [for (final r in rutas) DropdownMenuItem(value: r['id'] as String, child: Text('${r['nombre']}'))],
                onChanged: (v) => setLocal(() => rutaId = v),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: autoriza,
                onChanged: (v) => setLocal(() => autoriza = v ?? false),
                title: const Text('El cliente autoriza el tratamiento de sus datos (Ley 1581 de 2012)'),
              ),
            ]),
          ),
          actions: [
            if (perfil.esGestor)
              TextButton(onPressed: () => _nuevaRuta(ctx, ref).then((_) => ref.invalidate(rutasProvider)), child: const Text('Crear ruta')),
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
            FilledButton(onPressed: autoriza ? () => Navigator.pop(ctx, true) : null, child: const Text('Guardar')),
          ],
        ),
      ),
    );
    if (ok != true || !context.mounted) return;
    try {
      await ref.read(repoProvider).crearCliente({
        for (final e in campos.entries) if (e.value.text.trim().isNotEmpty) e.key: e.value.text.trim(),
        'ruta_id': rutaId,
        'autoriza_datos': autoriza,
      });
      ref.invalidate(_clientesProvider);
    } catch (e) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(mensajeError(e))));
    }
  }

  Future<void> _nuevaRuta(BuildContext context, WidgetRef ref) async {
    final nombre = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Nueva ruta'),
        content: TextField(controller: nombre, autofocus: true, decoration: const InputDecoration(labelText: 'Nombre')),
        actions: [FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Crear'))],
      ),
    );
    if (ok == true && nombre.text.trim().isNotEmpty) await ref.read(repoProvider).crearRuta(nombre.text.trim());
  }
}
