import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'core/services/app_services.dart';
import 'core/services/file_repository.dart';
import 'core/theme/app_theme.dart';
import 'features/converter/converter_controller.dart';
import 'features/files/files_controller.dart';
import 'features/home/home_shell.dart';

class PindaiinApp extends StatelessWidget {
  const PindaiinApp({super.key, required this.services});

  final AppServices services;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider<AppServices>.value(value: services),
        ChangeNotifierProvider<FileRepository>.value(value: services.repository),
        ChangeNotifierProvider(create: (_) => FilesController(services: services)),
        ChangeNotifierProvider(
          create: (_) => ConverterController(services: services),
        ),
      ],
      child: MaterialApp(
        title: 'Pindaiin',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        home: const HomeShell(),
      ),
    );
  }
}
