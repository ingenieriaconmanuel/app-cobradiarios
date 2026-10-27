import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/sesion.dart';
import '../features/auth/login_page.dart';
import '../features/auth/registro_empresa_page.dart';
import '../features/caja/caja_page.dart';
import '../features/clientes/clientes_page.dart';
import '../features/inicio/inicio_page.dart';
import '../features/prestamos/nuevo_prestamo_page.dart';
import '../features/ruta/ruta_page.dart';
import '../features/shell/shell_page.dart';
import '../features/usuarios/usuarios_page.dart';

final routerProvider = Provider<GoRouter>((ref) {
  final sesion = ref.watch(sesionProvider.notifier);

  return GoRouter(
    initialLocation: '/',
    refreshListenable: sesion,
    redirect: (context, state) {
      final ruta = state.matchedLocation;
      return switch (sesion.estado) {
        EstadoSesion.cargando => ruta == '/cargando' ? null : '/cargando',
        EstadoSesion.sinSesion => ruta == '/login' ? null : '/login',
        EstadoSesion.sinEmpresa => ruta == '/registro-empresa' ? null : '/registro-empresa',
        EstadoSesion.lista when const ['/cargando', '/login', '/registro-empresa'].contains(ruta) =>
          sesion.perfil!.esGestor ? '/' : '/ruta',
        EstadoSesion.lista => null,
      };
    },
    routes: [
      GoRoute(path: '/cargando', builder: (_, __) => const Scaffold(body: Center(child: CircularProgressIndicator()))),
      GoRoute(path: '/login', builder: (_, __) => const LoginPage()),
      GoRoute(path: '/registro-empresa', builder: (_, __) => const RegistroEmpresaPage()),
      ShellRoute(
        builder: (_, state, child) => ShellPage(ubicacion: state.matchedLocation, child: child),
        routes: [
          GoRoute(path: '/', builder: (_, __) => const InicioPage()),
          GoRoute(path: '/ruta', builder: (_, __) => const RutaPage()),
          GoRoute(path: '/clientes', builder: (_, __) => const ClientesPage()),
          GoRoute(
            path: '/prestamos/nuevo',
            builder: (_, state) => NuevoPrestamoPage(cliente: state.extra as Map<String, dynamic>?),
          ),
          GoRoute(path: '/caja', builder: (_, __) => const CajaPage()),
          GoRoute(path: '/usuarios', builder: (_, __) => const UsuariosPage()),
        ],
      ),
    ],
  );
});
