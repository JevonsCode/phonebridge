import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'app_language.dart';
import 'design.dart';

/// A local owner editor. Native state is the source of truth; cancel never writes.
class AppAccessPage extends StatefulWidget {
  const AppAccessPage({super.key, required this.snapshot, this.draft = false});
  final Map<String, dynamic> snapshot;
  final bool draft;
  @override
  State<AppAccessPage> createState() => _AppAccessPageState();
}

class _AppAccessPageState extends State<AppAccessPage> {
  static const channel = MethodChannel('dev.phonebridge/control');
  late final selected = Set<String>.from(
    widget.snapshot['allowedPackages'] as List,
  );
  late final apps = (widget.snapshot['apps'] as List)
      .map((e) => Map<String, dynamic>.from(e as Map))
      .toList();
  String query = '';
  String? error;
  bool saving = false;

  Future<void> save() async {
    if (saving) return;
    if (selected.isEmpty || selected.length > 64) {
      setState(() => error = '请选择 1–64 个应用');
      return;
    }
    if (widget.draft) {
      Navigator.pop(context, selected.toList());
      return;
    }
    setState(() {
      saving = true;
      error = null;
    });
    try {
      final result = await channel
          .invokeMapMethod<String, dynamic>('setAllowedPackages', {
            'computerId': widget.snapshot['activeComputerId'],
            'permissionRevision': widget.snapshot['permissionRevision'],
            'expectedPackages': widget.snapshot['allowedPackages'],
            'packages': selected.toList(),
          });
      final actual = result?['allowedPackages'];
      if (actual is! List ||
          !setEquals(Set<String>.from(actual), selected) ||
          result?['activeComputerId'] != widget.snapshot['activeComputerId']) {
        throw PlatformException(code: 'POLICY_CHANGED');
      }
      if (mounted) Navigator.pop(context, selected.toList());
    } on PlatformException catch (e) {
      if (mounted) {
        setState(() => error = userError(e.code, e.message, '无法保存应用授权，请重试'));
      }
    } on MissingPluginException {
      if (mounted) setState(() => error = '请更新安卓端 PhoneBridge 后再试');
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final search = query.trim().toLowerCase();
    final visible = apps
        .where(
          (app) => '${app['name']} ${app['packageName']}'
              .toLowerCase()
              .contains(search),
        )
        .toList();
    final selectable = visible
        .where((app) => app['protected'] != true && app['installed'] != false)
        .map((app) => app['packageName'] as String)
        .toSet();
    final allSelected = selected.containsAll(selectable);
    final displayError = selected.length > 64 ? '最多允许 64 个应用，请取消部分勾选' : error;
    final name = widget.snapshot['computerName'] as String? ?? '';
    return PopScope(
      canPop: !saving,
      child: Scaffold(
        appBar: AppBar(
          title: Text(tr(context, '允许访问的应用')),
          actions: [
            TextButton(
              key: const Key('save-app-access'),
              onPressed: saving ? null : save,
              child: Text(tr(context, saving ? '保存中…' : '保存')),
            ),
          ],
        ),
        body: SafeArea(
          child: CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (name.isNotEmpty) ...[
                        Text(
                          name,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 8),
                      ],
                      Text(tr(context, '仅允许电脑读取所选应用；开启“允许操作”后，也可以点击、滑动和输入。')),
                      const SizedBox(height: 8),
                      Text(
                        tr(context, '编辑期间暂停远程操作，返回后恢复。'),
                        style: const TextStyle(color: muted),
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        key: const Key('search-app-access'),
                        onChanged: (value) => setState(() => query = value),
                        decoration: InputDecoration(
                          prefixIcon: const Icon(Icons.search),
                          hintText: tr(context, '搜索应用名称或包名'),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 16,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text('${tr(context, '已选择')} ${selected.length} / 64'),
                          TextButton(
                            key: const Key('select-all-apps'),
                            onPressed: saving || allSelected
                                ? null
                                : () => setState(() {
                                    selected.addAll(selectable);
                                    error = null;
                                  }),
                            child: Text(
                              tr(context, search.isEmpty ? '全选' : '全选搜索结果'),
                            ),
                          ),
                        ],
                      ),
                      if (displayError != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Semantics(
                            liveRegion: true,
                            child: Text(
                              tr(context, displayError),
                              key: const Key('app-access-error'),
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              if (visible.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(child: Text(tr(context, '未找到应用，试试其他名称'))),
                )
              else
                SliverList(
                  delegate: SliverChildBuilderDelegate((context, index) {
                    final app = visible[index];
                    final package = app['packageName'] as String;
                    final protected = app['protected'] == true;
                    return CheckboxListTile(
                      key: Key('app-$package'),
                      value: selected.contains(package),
                      controlAffinity: ListTileControlAffinity.trailing,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 4,
                      ),
                      title: Text(
                        app['name'] as String,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        '$package${protected
                            ? '\n${tr(context, '系统授权页面仅能在手机操作')}'
                            : app['installed'] == false
                            ? '\n${tr(context, '当前未安装')}'
                            : ''}',
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onChanged:
                          saving || (protected && !selected.contains(package))
                          ? null
                          : (value) {
                              setState(() {
                                if (value == true) {
                                  selected.add(package);
                                } else {
                                  selected.remove(package);
                                }
                                error = null;
                              });
                            },
                    );
                  }, childCount: visible.length),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
