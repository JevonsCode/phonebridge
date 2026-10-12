import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'app_language.dart';
import 'design.dart';

class OperationHistoryPage extends StatefulWidget {
  const OperationHistoryPage({super.key, required this.computerName});
  final String computerName;
  @override
  State<OperationHistoryPage> createState() => _OperationHistoryPageState();
}

class _OperationHistoryPageState extends State<OperationHistoryPage> {
  static const channel = MethodChannel('dev.phonebridge/control');
  List<Map<String, dynamic>> records = [];
  bool loading = true;
  String? error;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final result =
          await channel.invokeMapMethod<String, dynamic>('operationHistory') ??
          {};
      final remote =
          jsonDecode(result['operations'] as String? ?? '[]') as List;
      final merged = [
        ...remote,
        ...?result['files'] as List?,
      ].whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
      // Android and the computer can emit different fractional precision and
      // timezone offsets. ISO strings must be parsed before merging their order.
      int timestamp(Map<String, dynamic> record) =>
          DateTime.tryParse(
            record['time'] as String? ?? '',
          )?.microsecondsSinceEpoch ??
          0;
      merged.sort((a, b) => timestamp(b).compareTo(timestamp(a)));
      if (mounted) {
        setState(() {
          records = merged;
          error = result['error'] as String?;
        });
      }
    } catch (_) {
      if (mounted) setState(() => error = '无法读取日志，请稍后刷新');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  String title(Map<String, dynamic> record) =>
      tr(context, switch (record['method']) {
        'state' => '读取界面',
        'screenshot' => '查看截图',
        'tap' => '点击',
        'long_press' => '长按',
        'swipe' => '滑动',
        'set_text' || 'commit_text' => '输入文字',
        'global_action' => '系统导航',
        'launch_app' => '打开应用',
        'file_offer' => '发送文件邀请',
        'file_transfer' => '文件传输',
        _ => '操作',
      });
  String outcome(Map<String, dynamic> record) =>
      tr(context, switch (record['status']) {
        'completed' =>
          record['method'] == 'file_offer' ? '邀请已送达，等待手机接收' : '设备已完成',
        'failed' => '失败',
        'uncertain' || 'started' => '结果不确定，请检查手机',
        'pending' => '等待接收',
        'receiving' => '正在接收',
        'received' => '已接收',
        'declined' => '已拒绝',
        'expired' => '已过期',
        'cancelled' => '连接中断',
        'share_opened' => '已打开分享面板，发送结果由目标应用确认',
        _ => '状态未知',
      });
  String time(Map<String, dynamic> record) {
    final date = DateTime.tryParse(record['time'] as String? ?? '')?.toLocal();
    if (date == null) return '';
    String pad(int n) => n.toString().padLeft(2, '0');
    return '${date.year}-${pad(date.month)}-${pad(date.day)}  ${pad(date.hour)}:${pad(date.minute)}:${pad(date.second)}';
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(tr(context, '操作日志')),
      actions: [
        IconButton(
          tooltip: tr(context, '刷新'),
          onPressed: loading ? null : load,
          icon: const Icon(Icons.refresh_rounded),
        ),
      ],
    ),
    body: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.computerName,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 6),
              Text(
                tr(context, '最近 100 条电脑操作与本机文件记录 · 最新在前'),
                style: const TextStyle(fontSize: 12),
              ),
              Text(
                tr(context, '不记录输入内容、截图或配对密钥'),
                style: const TextStyle(fontSize: 12),
              ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(
                    tr(context, error!),
                    style: const TextStyle(color: Color(0xFFA34726)),
                  ),
                ),
            ],
          ),
        ),
        if (loading) const LinearProgressIndicator(),
        Expanded(
          child: records.isEmpty
              ? Center(child: Text(tr(context, loading ? '正在读取日志…' : '暂无操作记录')))
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
                  itemCount: records.length,
                  itemBuilder: (context, index) {
                    final record = records[index];
                    final warning = [
                      'failed',
                      'uncertain',
                      'started',
                    ].contains(record['status']);
                    final color = warning ? const Color(0xFFA34726) : blue;
                    return Padding(
                      padding: const EdgeInsets.only(left: 7),
                      child: Container(
                        decoration: const BoxDecoration(
                          border: Border(
                            left: BorderSide(
                              color: Color(0xFFD8E1EE),
                              width: 2,
                            ),
                          ),
                        ),
                        padding: const EdgeInsets.only(left: 18, bottom: 24),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              time(record),
                              style: const TextStyle(
                                fontSize: 11,
                                color: muted,
                              ),
                            ),
                            const SizedBox(height: 5),
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Icon(
                                  warning
                                      ? Icons.error_outline_rounded
                                      : Icons.circle,
                                  size: 12,
                                  color: color,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    title(record),
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w500,
                                      color: ink,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 5),
                            Text(
                              outcome(record),
                              style: TextStyle(fontSize: 13, color: color),
                            ),
                            if (record['errorCode'] is String)
                              Text(
                                record['errorCode'],
                                style: const TextStyle(fontSize: 11),
                              ),
                            if ((record['sourceName'] as String? ?? '')
                                .isNotEmpty)
                              Text(
                                record['sourceName'],
                                style: const TextStyle(fontSize: 11),
                              ),
                            if (record['durationMs'] is num)
                              Text(
                                '${record['durationMs']} ms',
                                style: const TextStyle(fontSize: 11),
                              ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    ),
  );
}
