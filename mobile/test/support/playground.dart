import 'package:flutter/material.dart';

class PlaygroundPage extends StatefulWidget {
  const PlaygroundPage({super.key});
  @override
  State<PlaygroundPage> createState() => _PlaygroundPageState();
}

class _PlaygroundPageState extends State<PlaygroundPage> {
  int count = 0;
  String saved = '还没有保存文字';
  final text = TextEditingController();
  @override
  void dispose() {
    text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('操作练习场')),
    body: ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text('先在这里试一试', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 12),
        const Text(
          '让 AI 读取计数、点击加一，或输入并保存一段中文。这里的操作只影响这个页面。',
          style: TextStyle(height: 1.6),
        ),
        const SizedBox(height: 32),
        Semantics(
          liveRegion: true,
          child: Text(
            '当前计数：$count',
            key: const Key('counter'),
            style: Theme.of(context).textTheme.headlineMedium,
          ),
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: () => setState(() => count++),
          child: const Text('加一'),
        ),
        const SizedBox(height: 32),
        TextField(
          controller: text,
          decoration: const InputDecoration(labelText: '练习输入文字'),
          maxLength: 4000,
        ),
        const SizedBox(height: 16),
        OutlinedButton(
          onPressed: () {
            FocusScope.of(context).unfocus();
            setState(() => saved = text.text);
          },
          child: const Text('保存练习文字'),
        ),
        const SizedBox(height: 16),
        Text('已保存：$saved', key: const Key('saved')),
        const SizedBox(height: 400),
        const Text('你已滑动到练习场底部', textAlign: TextAlign.center),
      ],
    ),
  );
}
