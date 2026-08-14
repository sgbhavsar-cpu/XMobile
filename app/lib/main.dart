import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/router.dart';
import 'core/api/http_api_client.dart';
import 'core/state/providers.dart';

/// Opt-in real backend: `flutter run --dart-define=XMOBILE_API_BASE_URL=https://xmobile.internal/api`.
/// Left unset, the app runs against `MockApiClient` (today's default — see `apiClientProvider`);
/// `HttpApiClient` doesn't yet cover enough of `ApiClient` (opportunities, expenses, most
/// reference data, device tracking-health) to make it the unconditional default without breaking
/// those screens, so this is a deliberate opt-in rather than a flip.
const _apiBaseUrl = String.fromEnvironment('XMOBILE_API_BASE_URL');

void main() {
  final overrides = <Override>[
    if (_apiBaseUrl.isNotEmpty) apiClientProvider.overrideWithValue(HttpApiClient(baseUrl: _apiBaseUrl)),
  ];
  runApp(ProviderScope(overrides: overrides, child: const XMobileApp()));
}

class XMobileApp extends ConsumerWidget {
  const XMobileApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);

    return MaterialApp.router(
      title: 'XMobile',
      debugShowCheckedModeBanner: false,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      routerConfig: router,
    );
  }

  ThemeData _theme(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF1B5E7E),
      brightness: brightness,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      // Field use means gloves, sunlight and haste: generous targets, clear borders.
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
        isDense: false,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
      ),
      listTileTheme: const ListTileThemeData(visualDensity: VisualDensity.standard),
    );
  }
}
