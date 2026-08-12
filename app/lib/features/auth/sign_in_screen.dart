import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api/api_client.dart';
import '../../core/state/providers.dart';
import '../../core/ui/common.dart';
import '../../core/ui/form_fields.dart';

/// Sign-in. Against the real backend this becomes an OIDC redirect to Keycloak in the
/// system browser; the form stays for the offline-token-expired case, where a rep must
/// still be able to open the app and see their day.
class SignInScreen extends ConsumerStatefulWidget {
  const SignInScreen({super.key});

  @override
  ConsumerState<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends ConsumerState<SignInScreen> {
  final _formKey = GlobalKey<FormState>();
  final _employeeCode = TextEditingController(text: 'E1001');
  final _password = TextEditingController(text: 'demo1234');

  bool _busy = false;
  Map<String, String> _fieldErrors = {};

  @override
  void dispose() {
    _employeeCode.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _busy = true;
      _fieldErrors = {};
    });

    try {
      await ref
          .read(sessionProvider.notifier)
          .signIn(_employeeCode.text.trim(), _password.text);
      if (mounted) context.go('/today');
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _fieldErrors = e.fieldErrors);
      showApiError(context, e);
    } catch (e) {
      if (mounted) showApiError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Form(
                key: _formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Icon(Icons.route, size: 56, color: theme.colorScheme.primary),
                    const SizedBox(height: 16),
                    Text('XMobile',
                        style: theme.textTheme.headlineMedium, textAlign: TextAlign.center),
                    const SizedBox(height: 4),
                    Text(
                      'Sales force mobility',
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 32),
                    AppTextField(
                      label: 'Employee code',
                      controller: _employeeCode,
                      required: true,
                      errorText: _fieldErrors['employeeCode'],
                    ),
                    AppTextField(
                      label: 'Password',
                      controller: _password,
                      required: true,
                      errorText: _fieldErrors['password'],
                    ),
                    const SizedBox(height: 8),
                    FilledButton(
                      onPressed: _busy ? null : _signIn,
                      child: _busy
                          ? const SizedBox(
                              height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Text('Sign in'),
                    ),
                    const SizedBox(height: 24),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Row(
                          children: [
                            const Icon(Icons.info_outline, size: 18),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'Demo build — data lives on this device only. '
                                'Any code and a 4+ character password will sign you in.',
                                style: theme.textTheme.bodySmall,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
