import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositorio.dart';
import '../../data/sesion.dart';

class LoginPage extends ConsumerStatefulWidget {
  const LoginPage({super.key});

  @override
  ConsumerState<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends ConsumerState<LoginPage> {
  final _email = TextEditingController();
  final _clave = TextEditingController();
  bool _creando = false;
  bool _ocupado = false;
  String? _error;

  Future<void> _enviar() async {
    setState(() {
      _ocupado = true;
      _error = null;
    });
    final auth = ref.read(dbProvider).auth;
    try {
      if (_creando) {
        await auth.signUp(email: _email.text.trim(), password: _clave.text);
      } else {
        await auth.signInWithPassword(email: _email.text.trim(), password: _clave.text);
      }
    } catch (e) {
      setState(() => _error = mensajeError(e));
    } finally {
      if (mounted) setState(() => _ocupado = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.all(24),
            children: [
              Icon(Icons.payments_outlined, size: 56, color: Theme.of(context).colorScheme.primary),
              const SizedBox(height: 8),
              Text('CobraDiarios', textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineMedium),
              const SizedBox(height: 32),
              TextField(controller: _email, keyboardType: TextInputType.emailAddress, decoration: const InputDecoration(labelText: 'Correo')),
              const SizedBox(height: 12),
              TextField(controller: _clave, obscureText: true, decoration: const InputDecoration(labelText: 'Contraseña'), onSubmitted: (_) => _enviar()),
              if (_error != null) Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
              const SizedBox(height: 20),
              FilledButton(onPressed: _ocupado ? null : _enviar, child: Text(_creando ? 'Crear cuenta' : 'Ingresar')),
              TextButton(
                onPressed: () => setState(() => _creando = !_creando),
                child: Text(_creando ? 'Ya tengo cuenta' : 'Registrar mi empresa (14 días gratis)'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
