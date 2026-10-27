import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/sesion.dart';

typedef _Destino = ({String ruta, IconData icono, String etiqueta, bool soloGestor});

const List<_Destino> _destinos = [
  (ruta: '/', icono: Icons.dashboard_outlined, etiqueta: 'Inicio', soloGestor: true),
  (ruta: '/ruta', icono: Icons.route_outlined, etiqueta: 'Cobrar', soloGestor: false),
  (ruta: '/clientes', icono: Icons.people_outline, etiqueta: 'Clientes', soloGestor: false),
  (ruta: '/caja', icono: Icons.point_of_sale_outlined, etiqueta: 'Caja', soloGestor: false),
  (ruta: '/usuarios', icono: Icons.badge_outlined, etiqueta: 'Usuarios', soloGestor: true),
];

/// Web/tablet: NavigationRail. Teléfono: NavigationBar. Los destinos dependen del rol.
class ShellPage extends ConsumerWidget {
  const ShellPage({super.key, required this.ubicacion, required this.child});

  final String ubicacion;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final perfil = ref.watch(perfilProvider);
    final destinos = _destinos.where((d) => perfil.esGestor || !d.soloGestor).toList();
    final indice = destinos.indexWhere((d) => d.ruta == ubicacion).clamp(0, destinos.length - 1);
    final ancho = MediaQuery.sizeOf(context).width >= 800;
    void ir(int i) => context.go(destinos[i].ruta);

    return Scaffold(
      appBar: AppBar(
        title: Text(perfil.empresa),
        actions: [
          Center(child: Text('${perfil.nombre} · ${perfil.rol.name}')),
          IconButton(tooltip: 'Salir', icon: const Icon(Icons.logout), onPressed: () => ref.read(sesionProvider).salir()),
        ],
      ),
      body: Row(
        children: [
          if (ancho)
            NavigationRail(
              selectedIndex: indice,
              onDestinationSelected: ir,
              labelType: NavigationRailLabelType.all,
              destinations: [for (final d in destinos) NavigationRailDestination(icon: Icon(d.icono), label: Text(d.etiqueta))],
            ),
          Expanded(child: child),
        ],
      ),
      bottomNavigationBar: ancho
          ? null
          : NavigationBar(
              selectedIndex: indice,
              onDestinationSelected: ir,
              destinations: [for (final d in destinos) NavigationDestination(icon: Icon(d.icono), label: d.etiqueta)],
            ),
    );
  }
}
