import 'package:flutter/material.dart';

import 'exercise_engine.dart';
import 'live_test_screen.dart';

void main() {
  runApp(const SportsTalentApp());
}

class SportsTalentApp extends StatelessWidget {
  const SportsTalentApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Sports Talent App',
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple)),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  Future<void> _startVerticalJump(BuildContext context) async {
    final heightCm = await showDialog<double>(
      context: context,
      builder: (context) => const _HeightInputDialog(),
    );
    if (heightCm == null || !context.mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => LiveTestScreen(
          exerciseType: ExerciseType.verticalJump,
          userHeightCm: heightCm,
        ),
      ),
    );
  }

  void _startPushUp(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => const LiveTestScreen(exerciseType: ExerciseType.pushUp),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Sports Talent Assessment')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text(
                'Choose a test',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 32),
              ElevatedButton.icon(
                icon: const Icon(Icons.arrow_upward),
                label: const Text('Standing Vertical Jump'),
                onPressed: () => _startVerticalJump(context),
              ),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                icon: const Icon(Icons.fitness_center),
                label: const Text('Push-ups'),
                onPressed: () => _startPushUp(context),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HeightInputDialog extends StatefulWidget {
  const _HeightInputDialog();

  @override
  State<_HeightInputDialog> createState() => _HeightInputDialogState();
}

class _HeightInputDialogState extends State<_HeightInputDialog> {
  final _controller = TextEditingController();
  String? _errorText;

  void _submit() {
    final value = double.tryParse(_controller.text);
    if (value == null || value < 50 || value > 250) {
      setState(() => _errorText = 'Enter a height between 50 and 250 cm');
      return;
    }
    Navigator.of(context).pop(value);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Your Height'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(
          labelText: 'Height (cm)',
          errorText: _errorText,
        ),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(onPressed: _submit, child: const Text('Start')),
      ],
    );
  }
}
