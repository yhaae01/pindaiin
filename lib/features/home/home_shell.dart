import 'package:flutter/material.dart';

import '../converter/converter_screen.dart';
import '../files/files_screen.dart';
import '../scanner/scan_session_screen.dart';

/// Bottom navigation between the file hub and the converter, with a persistent
/// scan action.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  Future<void> _openScanner() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const ScanSessionScreen(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: [
          FilesScreen(onStartScan: _openScanner),
          ConverterScreen(onOpenFiles: () => setState(() => _index = 0)),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (index) => setState(() => _index = index),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.folder_outlined),
            selectedIcon: Icon(Icons.folder),
            label: 'Files',
          ),
          NavigationDestination(
            icon: Icon(Icons.swap_horiz_outlined),
            selectedIcon: Icon(Icons.swap_horiz),
            label: 'Convert',
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openScanner,
        icon: const Icon(Icons.document_scanner_outlined),
        label: const Text('Scan'),
      ),
    );
  }
}
