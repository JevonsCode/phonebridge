import 'package:flutter/material.dart';
import 'app_language.dart';
import 'design.dart';

String fileSize(num bytes) => bytes < 1024 * 1024
    ? '${(bytes / 1024).toStringAsFixed(1)} KB'
    : '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';

typedef FileAction = Future<void> Function(String method, String id);

bool _needsAnswer(Map<String, dynamic> file) =>
    file['state'] == 'pending' || file['state'] == 'receiving';

/// Home keeps one row; the list lives on its own page.
class FileInboxEntry extends StatelessWidget {
  const FileInboxEntry({super.key, required this.files, required this.onOpen});
  final List<Map<String, dynamic>> files;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final waiting = files.where(_needsAnswer).length;
    return SurfaceGroup(
      children: [
        SettingsRow(
          key: const Key('file-inbox-entry'),
          icon: Icons.inbox_outlined,
          title: '来自电脑的文件',
          subtitle: waiting > 0
              ? tr(context, '有文件等待你接收')
              : '${files.length} ${tr(context, '个文件')}',
          onTap: onOpen,
          trailing: waiting > 0 ? const _Badge(color: blue, text: '!') : null,
        ),
      ],
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.color, required this.text});
  final Color color;
  final String text;
  @override
  Widget build(BuildContext context) => Container(
    width: 22,
    height: 22,
    alignment: Alignment.center,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    child: Text(
      text,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 12,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}

class FileInboxPage extends StatefulWidget {
  const FileInboxPage({
    super.key,
    required this.files,
    required this.onAction,
    this.onOpenFolder,
    this.onCleanup,
    this.pageSize = 20,
  });

  /// Updated by the connection page's status polling.
  final ValueNotifier<List<Map<String, dynamic>>> files;
  final FileAction onAction;
  final VoidCallback? onOpenFolder;

  /// Deletes finished files older than the given days (null: all); returns the count.
  final Future<int?> Function(int? olderThanDays)? onCleanup;
  final int pageSize;

  @override
  State<FileInboxPage> createState() => _FileInboxPageState();
}

class _FileInboxPageState extends State<FileInboxPage> {
  late int shown = widget.pageSize;
  final working = <String>{};

  Future<void> cleanup() async {
    final days = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text(
                tr(context, '清理旧文件'),
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text(
                tr(context, '会从手机上删除这些文件。等待接收的文件不受影响。'),
                style: const TextStyle(fontSize: 13, color: muted),
              ),
            ),
            // 0 stands for every finished file; the sheet result cannot be null-valued.
            for (final choice in const {
              7: '7 天前的文件',
              30: '30 天前的文件',
              0: '全部文件',
            }.entries)
              ListTile(
                key: Key('cleanup-${choice.key}'),
                title: Text(tr(context, choice.value)),
                onTap: () => Navigator.pop(sheetContext, choice.key),
              ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
    if (days == null || !mounted) return;
    final count = await widget.onCleanup!(days == 0 ? null : days);
    if (count == null || !mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            count == 0
                ? tr(context, '没有符合条件的文件')
                : '${tr(context, '已清理')} $count ${tr(context, '个文件')}',
          ),
        ),
      );
  }

  Future<void> act(String method, String id) async {
    if (working.contains(id)) return;
    setState(() => working.add(id));
    try {
      await widget.onAction(method, id);
    } finally {
      if (mounted) setState(() => working.remove(id));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(tr(context, '来自电脑的文件')),
      actions: [
        if (widget.onOpenFolder != null)
          IconButton(
            key: const Key('file-inbox-folder'),
            tooltip: tr(context, '打开文件夹'),
            onPressed: widget.onOpenFolder,
            icon: const Icon(Icons.folder_open_outlined),
          ),
        if (widget.onCleanup != null)
          IconButton(
            key: const Key('file-inbox-cleanup'),
            tooltip: tr(context, '清理旧文件'),
            onPressed: cleanup,
            icon: const Icon(Icons.delete_sweep_outlined),
          ),
        const SizedBox(width: 8),
      ],
    ),
    body: SafeArea(
      child: ValueListenableBuilder(
        valueListenable: widget.files,
        builder: (context, files, _) {
          // Files waiting for an answer come first; the rest stay newest first.
          final ordered = [
            ...files.where(_needsAnswer),
            ...files.where((f) => !_needsAnswer(f)),
          ];
          if (ordered.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  tr(context, '还没有收到文件'),
                  key: const Key('file-inbox-empty'),
                  style: const TextStyle(color: muted),
                ),
              ),
            );
          }
          final visible = ordered.take(shown).toList();
          final remaining = ordered.length - visible.length;
          return Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: ListView.builder(
                key: const Key('file-inbox-list'),
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                itemCount: visible.length + 2,
                itemBuilder: (context, index) {
                  if (index == 0) {
                    return Padding(
                      padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
                      child: Text(
                        '${tr(context, '接收后点分享，选择微信、WhatsApp 或其他应用')}\n'
                        '${tr(context, '文件保存在「下载/PhoneBridge」，也可以在系统文件管理里查看和删除。')}',
                        style: const TextStyle(fontSize: 12, color: muted),
                      ),
                    );
                  }
                  if (index == visible.length + 1) {
                    if (remaining <= 0) return const SizedBox.shrink();
                    return Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: TextButton(
                        key: const Key('file-inbox-more'),
                        onPressed: () =>
                            setState(() => shown += widget.pageSize),
                        child: Text('${tr(context, '显示更多')} ($remaining)'),
                      ),
                    );
                  }
                  final file = visible[index - 1];
                  return FileRow(
                    file: file,
                    busy: working.contains(file['id']),
                    onAction: act,
                  );
                },
              ),
            ),
          );
        },
      ),
    ),
  );
}

class FileRow extends StatelessWidget {
  const FileRow({
    super.key,
    required this.file,
    required this.busy,
    required this.onAction,
  });
  final Map<String, dynamic> file;
  final bool busy;
  final FileAction onAction;

  static IconData iconFor(String name) {
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    if (['png', 'jpg', 'jpeg', 'gif', 'webp', 'heic'].contains(ext)) {
      return Icons.image_outlined;
    }
    if (['mp4', 'mov', 'mkv', 'webm'].contains(ext)) {
      return Icons.movie_outlined;
    }
    if ([
      'pdf',
      'doc',
      'docx',
      'txt',
      'md',
      'xls',
      'xlsx',
      'ppt',
      'pptx',
    ].contains(ext)) {
      return Icons.description_outlined;
    }
    return Icons.insert_drive_file_outlined;
  }

  @override
  Widget build(BuildContext context) {
    final id = file['id'] as String;
    final state = file['state'] as String?;
    final name = file['name'] as String? ?? '';
    final error = file['error'] as String? ?? '';
    final stateText = tr(context, switch (state) {
      'pending' => '等待你接收',
      'receiving' => '正在接收并校验…',
      'received' => '已接收',
      'declined' => '已拒绝',
      'expired' => '文件已过期，请让电脑重新发送',
      'cancelled' => '连接已断开，请让电脑重新发送',
      _ => '接收失败，请让电脑重新发送',
    });
    final details = [
      if ((file['sourceName'] as String? ?? '').isNotEmpty) file['sourceName'],
      fileSize(file['size'] as num? ?? 0),
      if (state != 'received') stateText,
    ].join(' · ');
    return Container(
      key: Key('file-$id'),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(14, 10, 4, 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: const Color(0xFFF0F3F8),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(iconFor(name), size: 20, color: muted),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: ink,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      details,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12, color: muted),
                    ),
                  ],
                ),
              ),
              ...actions(context, id, state),
            ],
          ),
          if (error.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 52, top: 4, right: 10),
              child: Text(
                tr(context, error),
                style: const TextStyle(color: Color(0xFFA34726), fontSize: 12),
              ),
            ),
          if (state == 'receiving')
            const Padding(
              padding: EdgeInsets.only(left: 52, top: 8, right: 10),
              child: LinearProgressIndicator(minHeight: 3),
            ),
        ],
      ),
    );
  }

  List<Widget> actions(BuildContext context, String id, String? state) {
    final compact = ButtonStyle(
      visualDensity: VisualDensity.compact,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: 14),
      ),
      minimumSize: const WidgetStatePropertyAll(Size(0, 34)),
      textStyle: WidgetStatePropertyAll(
        Theme.of(context).textTheme.labelLarge?.copyWith(fontSize: 13),
      ),
    );
    if (state == 'pending') {
      return [
        const SizedBox(width: 8),
        // Large accessibility text shrinks the label instead of overflowing.
        Flexible(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: FilledButton(
              key: Key('receive-$id'),
              style: compact,
              onPressed: busy ? null : () => onAction('receiveFile', id),
              child: Text(tr(context, '接收')),
            ),
          ),
        ),
        IconButton(
          key: Key('decline-$id'),
          tooltip: tr(context, '拒绝'),
          visualDensity: VisualDensity.compact,
          onPressed: busy ? null : () => onAction('declineFile', id),
          icon: const Icon(Icons.close_rounded, size: 20),
        ),
      ];
    }
    if (state == 'receiving') return const [SizedBox(width: 10)];
    return [
      if (state == 'received')
        IconButton(
          key: Key('share-$id'),
          tooltip: tr(context, '分享'),
          visualDensity: VisualDensity.compact,
          color: blue,
          onPressed: busy ? null : () => onAction('shareFile', id),
          icon: const Icon(Icons.ios_share_rounded, size: 20),
        ),
      PopupMenuButton<String>(
        key: Key('more-$id'),
        tooltip: tr(context, '更多'),
        enabled: !busy,
        icon: const Icon(Icons.more_vert_rounded, size: 20, color: muted),
        onSelected: (method) => onAction(method, id),
        itemBuilder: (context) => [
          PopupMenuItem(
            key: Key('remove-$id'),
            value: 'removeReceivedFile',
            child: Text(tr(context, '移除')),
          ),
        ],
      ),
    ];
  }
}
