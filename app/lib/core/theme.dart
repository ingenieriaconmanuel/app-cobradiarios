import 'package:flutter/material.dart';

const _semilla = Color(0xFF0F766E);

final temaClaro = ThemeData(
  colorScheme: ColorScheme.fromSeed(seedColor: _semilla),
  useMaterial3: true,
  inputDecorationTheme: const InputDecorationTheme(border: OutlineInputBorder()),
);

final temaOscuro = ThemeData(
  colorScheme: ColorScheme.fromSeed(seedColor: _semilla, brightness: Brightness.dark),
  useMaterial3: true,
  inputDecorationTheme: const InputDecorationTheme(border: OutlineInputBorder()),
);
