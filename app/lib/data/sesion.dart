import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

enum Rol { admin, supervisor, cobrador }

class Perfil {
  Perfil({required this.id, required this.tenantId, required this.nombre, required this.rol, required this.empresa});

  factory Perfil.desdeMapa(Map<String, dynamic> m) => Perfil(
        id: m['id'] as String,
        tenantId: m['tenant_id'] as String,
        nombre: m['nombre'] as String,
        rol: Rol.values.byName(m['rol'] as String),
        empresa: (m['tenants'] as Map?)?['nombre'] as String? ?? '',
      );

  final String id;
  final String tenantId;
  final String nombre;
  final Rol rol;
  final String empresa;

  bool get esGestor => rol != Rol.cobrador;

  Map<String, dynamic> aMapa() => {
        'id': id,
        'tenant_id': tenantId,
        'nombre': nombre,
        'rol': rol.name,
        'tenants': {'nombre': empresa},
      };
}

const _clavePerfil = 'perfil_cache';

enum EstadoSesion { cargando, sinSesion, sinEmpresa, lista }

/// Fuente única del estado de sesión. El router la escucha para redirigir.
class SesionController extends ChangeNotifier {
  SesionController(this._db) {
    _sub = _db.auth.onAuthStateChange.listen((_) => recargar());
    recargar();
  }

  final SupabaseClient _db;
  late final StreamSubscription<AuthState> _sub;

  EstadoSesion estado = EstadoSesion.cargando;
  Perfil? perfil;

  Future<void> recargar() async {
    final usuario = _db.auth.currentUser;
    if (usuario == null) {
      perfil = null;
      estado = EstadoSesion.sinSesion;
    } else {
      final prefs = await SharedPreferences.getInstance();
      try {
        final fila = await _db
            .from('perfiles')
            .select('id, tenant_id, nombre, rol, tenants(nombre)')
            .eq('id', usuario.id)
            .maybeSingle()
            .timeout(const Duration(seconds: 10));
        perfil = fila == null ? null : Perfil.desdeMapa(fila);
        if (perfil != null) await prefs.setString(_clavePerfil, jsonEncode(perfil!.aMapa()));
      } catch (_) {
        // Sin señal: arrancar con el último perfil guardado de este mismo usuario
        final guardado = prefs.getString(_clavePerfil);
        final mapa = guardado == null ? null : jsonDecode(guardado) as Map<String, dynamic>;
        perfil = mapa != null && mapa['id'] == usuario.id ? Perfil.desdeMapa(mapa) : null;
        if (perfil == null) {
          // Primer ingreso sin señal: seguir en "cargando" y reintentar
          Future.delayed(const Duration(seconds: 5), recargar);
          return;
        }
      }
      estado = perfil == null ? EstadoSesion.sinEmpresa : EstadoSesion.lista;
    }
    notifyListeners();
  }

  Future<void> salir() async {
    (await SharedPreferences.getInstance()).remove(_clavePerfil);
    await _db.auth.signOut();
  }

  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }
}

final dbProvider = Provider<SupabaseClient>((_) => Supabase.instance.client);

final sesionProvider = ChangeNotifierProvider<SesionController>((ref) => SesionController(ref.watch(dbProvider)));

final perfilProvider = Provider<Perfil>((ref) => ref.watch(sesionProvider).perfil!);
