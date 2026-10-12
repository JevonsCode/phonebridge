import 'package:flutter/material.dart';
import 'app_language.dart';
import 'design.dart';

String fileSize(num bytes) => bytes < 1024 * 1024
    ? '${(bytes / 1024).toStringAsFixed(1)} KB'
    : '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';

class FileInboxCard extends StatelessWidget {
  const FileInboxCard({
    super.key,
    required this.files,
    required this.busy,
    required this.onAction,
  });
  final List<Map<String, dynamic>> files;
  final bool busy;
  final void Function(String method, String id) onAction;
  @override
  Widget build(BuildContext context) => SurfaceGroup(
    children: [
      Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              tr(context, '来自电脑的文件'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 6),
            Text(
              tr(context, '接收后点分享，选择微信、WhatsApp 或其他应用'),
              style: const TextStyle(fontSize: 12),
            ),
            for (final file in files) ...[
              const SizedBox(height: 16),
              Text(
                file['name'] as String? ?? '',
                style: const TextStyle(color: ink, fontWeight: FontWeight.w500),
              ),
              const SizedBox(height: 4),
              Text(
                '${file['sourceName'] ?? ''} · ${fileSize(file['size'] as num? ?? 0)}',
                style: const TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 6),
              Text(
                tr(context, switch (file['state']) {
                  'pending' => '等待你接收',
                  'receiving' => '正在接收并校验…',
                  'received' => '已接收',
                  'declined' => '已拒绝',
                  'expired' => '文件已过期，请让电脑重新发送',
                  'cancelled' => '连接已断开，请让电脑重新发送',
                  _ => '接收失败，请让电脑重新发送',
                }),
                style: const TextStyle(fontSize: 12),
              ),
              if ((file['error'] as String? ?? '').isNotEmpty)
                Text(
                  tr(context, file['error']),
                  style: const TextStyle(
                    color: Color(0xFFA34726),
                    fontSize: 12,
                  ),
                ),
              if (file['state'] == 'receiving')
                const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: LinearProgressIndicator(),
                ),
              Wrap(
                spacing: 12,
                children: [
                  if (file['state'] == 'pending') ...[
                    FilledButton(
                      onPressed: busy
                          ? null
                          : () => onAction('receiveFile', file['id']),
                      child: Text(tr(context, '接收')),
                    ),
                    TextButton(
                      onPressed: busy
                          ? null
                          : () => onAction('declineFile', file['id']),
                      child: Text(tr(context, '拒绝')),
                    ),
                  ],
                  if (file['state'] == 'received')
                    FilledButton.icon(
                      onPressed: busy
                          ? null
                          : () => onAction('shareFile', file['id']),
                      icon: const Icon(Icons.ios_share_rounded, size: 18),
                      label: Text(tr(context, '分享')),
                    ),
                  if (!['pending', 'receiving'].contains(file['state']))
                    TextButton(
                      onPressed: busy
                          ? null
                          : () => onAction('removeReceivedFile', file['id']),
                      child: Text(tr(context, '移除')),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    ],
  );
}
