import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/formato.dart';
import '../../data/repositorio.dart';

/// Simula en el servidor (misma lógica que al crear) y luego crea el préstamo.
class NuevoPrestamoPage extends ConsumerStatefulWidget {
  const NuevoPrestamoPage({super.key, this.cliente});
  final Fila? cliente;

  @override
  ConsumerState<NuevoPrestamoPage> createState() => _NuevoPrestamoPageState();
}

class _NuevoPrestamoPageState extends ConsumerState<NuevoPrestamoPage> {
  final _capital = TextEditingController(text: '100000');
  final _tasa = TextEditingController(text: '20');
  final _cuotas = TextEditingController(text: '24');
  final _mora = TextEditingController(text: '0');
  String _frecuencia = 'diario';
  String _tipo = 'flat';
  Fila? _simulacion;
  Fila? _anterior; // préstamo activo a renovar
  bool _renovar = false;
  bool _ocupado = false;

  @override
  void initState() {
    super.initState();
    final id = widget.cliente?['id'] as String?;
    if (id != null) {
      ref.read(repoProvider).prestamosActivos(id).then((l) {
        if (mounted && l.isNotEmpty) setState(() => _anterior = l.first);
      });
    }
  }

  ParamsPrestamo get _params => ParamsPrestamo(
        capital: num.parse(_capital.text),
        tasa: num.parse(_tasa.text.replaceAll(',', '.')) / 100,
        numCuotas: int.parse(_cuotas.text),
        frecuencia: _frecuencia,
        tipoInteres: _tipo,
        moraPctDiaria: num.parse(_mora.text.replaceAll(',', '.')) / 100,
      );

  Future<void> _ejecutar(Future<void> Function() accion) async {
    setState(() => _ocupado = true);
    try {
      await accion();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(mensajeError(e))));
    } finally {
      if (mounted) setState(() => _ocupado = false);
    }
  }

  Future<void> _simular() => _ejecutar(() async {
        final s = await ref.read(repoProvider).simularPrestamo(_params);
        setState(() => _simulacion = s);
      });

  Future<void> _crear() => _ejecutar(() async {
        final r = await ref.read(repoProvider).crearPrestamo(
              widget.cliente!['id'] as String,
              _params,
              renovarId: _renovar ? _anterior!['id'] as String : null,
            );
        if (!mounted) return;
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Préstamo creado'),
            content: Text('Entregar en efectivo: ${pesos(r['efectivo_entregado'])}\n'
                'Cuota: ${pesos(r['valor_cuota'])}\nPrimera cuota: ${fecha(r['fecha_primera_cuota'])}'),
            actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Listo'))],
          ),
        );
        if (mounted) context.go('/clientes');
      });

  @override
  Widget build(BuildContext context) {
    final cliente = widget.cliente;
    if (cliente == null) return const Center(child: Text('Seleccione un cliente desde la lista de clientes'));
    final s = _simulacion;
    final esquema = Theme.of(context).colorScheme;
    final numerico = [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))];

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Préstamo para ${cliente['nombre']}', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 16),
        Wrap(spacing: 12, runSpacing: 12, children: [
          SizedBox(width: 180, child: TextField(controller: _capital, inputFormatters: numerico, decoration: const InputDecoration(labelText: 'Capital', prefixText: r'$ '))),
          SizedBox(
            width: 180,
            child: TextField(
              controller: _tasa,
              inputFormatters: numerico,
              decoration: InputDecoration(labelText: _tipo == 'flat' ? 'Interés total %' : 'Interés por periodo %'),
            ),
          ),
          SizedBox(width: 120, child: TextField(controller: _cuotas, inputFormatters: numerico, decoration: const InputDecoration(labelText: 'Cuotas'))),
          SizedBox(
            width: 160,
            child: DropdownButtonFormField(
              value: _frecuencia,
              decoration: const InputDecoration(labelText: 'Frecuencia'),
              items: const [
                DropdownMenuItem(value: 'diario', child: Text('Diario')),
                DropdownMenuItem(value: 'semanal', child: Text('Semanal')),
                DropdownMenuItem(value: 'quincenal', child: Text('Quincenal')),
                DropdownMenuItem(value: 'mensual', child: Text('Mensual')),
              ],
              onChanged: (v) => setState(() => _frecuencia = v!),
            ),
          ),
          SizedBox(
            width: 200,
            child: DropdownButtonFormField(
              value: _tipo,
              decoration: const InputDecoration(labelText: 'Tipo de interés'),
              items: const [
                DropdownMenuItem(value: 'flat', child: Text('Flat (sobre capital)')),
                DropdownMenuItem(value: 'frances', child: Text('Cuota fija (francés)')),
                DropdownMenuItem(value: 'solo_interes', child: Text('Solo interés')),
              ],
              onChanged: (v) => setState(() => _tipo = v!),
            ),
          ),
          SizedBox(width: 160, child: TextField(controller: _mora, inputFormatters: numerico, decoration: const InputDecoration(labelText: 'Mora % diaria'))),
        ]),
        if (_anterior != null)
          CheckboxListTile(
            value: _renovar,
            onChanged: (v) => setState(() => _renovar = v ?? false),
            title: Text('Renovar préstamo #${_anterior!['numero']} (saldo ${pesos(_anterior!['saldo'])})'),
            subtitle: const Text('El saldo pendiente se descuenta del efectivo a entregar'),
          ),
        const SizedBox(height: 16),
        Row(children: [
          OutlinedButton.icon(onPressed: _ocupado ? null : _simular, icon: const Icon(Icons.calculate_outlined), label: const Text('Simular')),
          const SizedBox(width: 12),
          FilledButton.icon(
            onPressed: _ocupado || s == null ? null : _crear,
            icon: const Icon(Icons.check),
            label: const Text('Crear préstamo'),
          ),
        ]),
        if (s != null) ...[
          const SizedBox(height: 20),
          if (s['supera_usura'] == true)
            Card(
              color: esquema.errorContainer,
              child: ListTile(
                leading: const Icon(Icons.gavel),
                title: Text('Tasa ${porcentaje(s['tasa_ea'])} E.A. supera la usura (${porcentaje(s['tasa_usura_ea'])})'),
                subtitle: Text(s['politica_usura'] == 'bloquear'
                    ? 'El sistema no permitirá crear este préstamo. Ajuste la tasa o el plazo.'
                    : 'Advertencia: cobrar por encima de la tasa de usura es delito (art. 305 C.P.).'),
              ),
            ),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Wrap(spacing: 32, runSpacing: 8, children: [
                _dato('Cuota', pesos(s['valor_cuota'])),
                _dato('Total a pagar', pesos(s['total_a_pagar'])),
                _dato('Interés', pesos(s['interes_total'])),
                _dato('Primera cuota', fecha(s['fecha_primera_cuota'])),
                _dato('Última cuota', fecha(s['fecha_ultima_cuota'])),
                _dato('Tasa E.A.', porcentaje(s['tasa_ea'])),
              ]),
            ),
          ),
          ExpansionTile(
            title: Text('Plan de pagos (${(s['cuotas'] as List).length} cuotas)'),
            children: [
              for (final c in s['cuotas'] as List)
                ListTile(dense: true, leading: Text('${c['numero']}'), title: Text(fecha(c['fecha_vencimiento'])), trailing: Text(pesos(c['valor']))),
            ],
          ),
        ],
      ],
    );
  }

  Widget _dato(String titulo, String valor) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(titulo, style: Theme.of(context).textTheme.labelMedium),
        Text(valor, style: Theme.of(context).textTheme.titleMedium),
      ]);
}
