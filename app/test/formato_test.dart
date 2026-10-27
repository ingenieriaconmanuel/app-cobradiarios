import 'package:cobradiarios/core/formato.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

void main() {
  setUpAll(() => initializeDateFormatting('es_CO'));

  test('aNum acepta String y num', () {
    expect(aNum('5000.00'), 5000);
    expect(aNum(12), 12);
    expect(aNum(null), 0);
  });

  test('porcentaje', () => expect(porcentaje('0.2682'), '26.82 %'));

  test('pesos sin decimales', () => expect(pesos('120000.00'), contains('120.000')));
}
