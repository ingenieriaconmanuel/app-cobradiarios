import 'package:intl/intl.dart';

final _pesos = NumberFormat.currency(locale: 'es_CO', symbol: r'$', decimalDigits: 0);
final _fecha = DateFormat('EEE d MMM yyyy', 'es_CO');

/// Postgres devuelve numeric como String o num según el driver; aceptar ambos.
num aNum(Object? v) => v is num ? v : num.tryParse('$v') ?? 0;

String pesos(Object? v) => _pesos.format(aNum(v));

String fecha(Object? v) => v == null ? '' : _fecha.format(DateTime.parse('$v'));

String porcentaje(Object? v) => '${(aNum(v) * 100).toStringAsFixed(2)} %';
