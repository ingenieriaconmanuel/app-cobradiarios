import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositorio.dart';
import '../../data/sesion.dart';

/// Después de crear la cuenta, el usuario registra su empresa y queda como admin.
class RegistroEmpresaPage extends ConsumerStatefulWidget {
  const RegistroEmpresaPage({super.key});

  @override
  ConsumerState<RegistroEmpresaPage> createState() => _RegistroEmpresaPageState();
}

class _RegistroEmpresaPageState extends ConsumerState<RegistroEmpresaPage> {
  final _empresa = TextEditingController();
  final _nombre = TextEditingController();
  final _nit = TextEditingController();
  final _telefono = TextEditingController();
  final _ciudad = TextEditingController();
  String? _error;

  Future<void> _registrar() async {
    try {
      await ref.read(dbProvider).rpc('registrar_empresa', params: {
        'p_nombre_empresa': _empresa.text.trim(),
        'p_nombre_admin': _nombre.text.trim(),
        'p_nit': _nit.text.trim(),
        'p_telefono': _telefono.text.trim(),
        'p_ciudad': _ciudad.text.trim(),
      });
      await ref.read(sesionProvider).recargar();
    } catch (e) {
      setState(() => _error = mensajeError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Datos de su empresa'),
        actions: [IconButton(icon: const Icon(Icons.logout), onPressed: () => ref.read(sesionProvider).salir())],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              for (final (c, l) in [
                (_empresa, 'Nombre de la empresa *'),
                (_nombre, 'Su nombre *'),
                (_nit, 'NIT o cédula'),
                (_telefono, 'Teléfono / WhatsApp'),
                (_ciudad, 'Ciudad'),
              ]) Padding(padding: const EdgeInsets.only(bottom: 12), child: TextField(controller: c, decoration: InputDecoration(labelText: l))),
              if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              const SizedBox(height: 12),
              FilledButton(onPressed: _registrar, child: const Text('Comenzar prueba gratis')),
            ],
          ),
        ),
      ),
    );
  }
}
