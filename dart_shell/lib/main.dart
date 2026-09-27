import 'denial.dart';
import 'macos_shell.dart';

Future<void> main() async {
  await runDenialShell(shell: const MacosShellApp());
}
