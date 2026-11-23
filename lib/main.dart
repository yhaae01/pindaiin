import 'package:flutter/widgets.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';

import 'app.dart';
import 'core/services/app_services.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Hive stores only metadata (paths, names, sizes), never file contents.
  await Hive.initFlutter();
  final services = await AppServices.bootstrap();

  runApp(PindaiinApp(services: services));
}
