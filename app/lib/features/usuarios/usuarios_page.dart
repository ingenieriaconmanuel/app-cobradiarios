import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositorio.dart';
import '../../data/sesion.dart';
import '../clientes/clientes_page.dart' show rutasProvider;

final _usuariosProvider = FutureProvider.autoDispose(
  (ref) => ref.watch(dbProvider).from('perfiles').select('id, nombre, rol, activo, telefono').order('nombre'),
);

/// El admin del tenant administra sus propios usuarios (cobradores, supervisores, admins).
class UsuariosPage extends ConsumerWidget {
  const UsuariosPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final usuarios = ref.watch(_usuariosProvider);
    final esAdmin = ref.watch(perfilProvider).rol == Rol.admin;
    return Scaffold(
      floatingActionButton: esAdmin
          ? FloatingActionButton.extended(onPressed: () => _invitar(context, ref), icon: const Icon(Icons.person_add), label: const Text('Usuario'))
          : null,
      body: usuarios.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text(mensajeError(e))),
        data: (lista) => ListView(children: [
          for (final u in lista)
            SwitchListTile(
              title: Text('${u['nombre']}'),
              subtitle: Text('${u['rol']} · ${u['telefono'] ?? ''}'),
              value: u['activo'] == true,
              onChanged: esAdmin
                  ? (v) async {
                      try {
                        await ref.read(dbProvider).from('perfiles').update({'activo': v}).eq('id', u['id']);
                        ref.invalidate(_usuariosProvider);
                      } catch (e) {
                        if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(mensajeError(e))));
                      }
                    }
                  : null,
            ),
        ]),
      ),
    );
  }

  Future<void> _invitar(BuildContext context, WidgetRef ref) async {
    final nombre = TextEditingController();
    final email = TextEditingController();
    final clave = TextEditingController();
    final telefono = TextEditingController();
    var rol = 'cobrador';
    final rutasSel = <String>{};
    final rutas = await ref.read(rutasProvider.future);
    if (!context.mounted) return;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Nuevo usuario'),
          content: SizedBox(
            width: 420,
            child: ListView(shrinkWrap: true, children: [
              TextField(controller: nombre, decoration: const InputDecoration(labelText: 'Nombre')),
              const SizedBox(height: 10),
              TextField(controller: email, decoration: const InputDecoration(labelText: 'Correo (usuario de ingreso)')),
              const SizedBox(height: 10),
              TextField(controller: clave, decoration: const InputDecoration(labelText: 'Contraseña temporal (mín. 8)')),
              const SizedBox(height: 10),
              TextField(controller: telefono, decoration: const InputDecoration(labelText: 'Teléfono')),
              const SizedBox(height: 10),
              DropdownButtonFormField(
                value: rol,
                decoration: const InputDecoration(labelText: 'Rol'),
                items: const [
                  DropdownMenuItem(value: 'cobrador', child: Text('Cobrador')),
                  DropdownMenuItem(value: 'supervisor', child: Text('Supervisor')),
                  DropdownMenuItem(value: 'admin', child: Text('Administrador')),
                ],
                onChanged: (v) => setLocal(() => rol = v!),
              ),
              const SizedBox(height: 8),
              const Text('Rutas asignadas'),
              for (final r in rutas)
                CheckboxListTile(
                  dense: true,
                  value: rutasSel.contains(r['id']),
                  title: Text('${r['nombre']}'),
                  onChanged: (v) => setLocal(() => v == true ? rutasSel.add(r['id'] as String) : rutasSel.remove(r['id'])),
                ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Crear')),
          ],
        ),
      ),
    );
    if (ok != true || !context.mounted) return;
    try {
      await ref.read(repoProvider).invitarUsuario({
        'nombre': nombre.text.trim(),
        'email': email.text.trim(),
        'password': clave.text,
        'telefono': telefono.text.trim(),
        'rol': rol,
        'ruta_ids': rutasSel.toList(),
      });
      ref.invalidate(_usuariosProvider);
    } catch (e) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(mensajeError(e))));
    }
  }
}
