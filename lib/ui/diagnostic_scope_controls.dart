import 'package:flutter/material.dart';

import '../core/playback_diagnostic_snapshot.dart';

class DiagnosticScopeControls extends StatelessWidget {
  const DiagnosticScopeControls({
    super.key,
    required this.scope,
    this.onChanged,
  });

  final DiagnosticLogScope scope;
  final ValueChanged<DiagnosticLogScope>? onChanged;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      for (final value in DiagnosticLogScope.values)
        ChoiceChip(
          key: ValueKey('diagnostic-scope-${value.name}'),
          label: Text(
            value == DiagnosticLogScope.currentPlayback ? '本次播放' : '全部日志',
          ),
          selected: scope == value,
          onSelected: onChanged == null ? null : (_) => onChanged!(value),
        ),
    ],
  );
}

class PlaybackDiagnosticSummaryCard extends StatelessWidget {
  const PlaybackDiagnosticSummaryCard({super.key, required this.summary});
  final PlaybackDiagnosticSummary summary;

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.symmetric(vertical: 12),
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            summary.closed ? '最近一次播放（已结束）' : '本次播放状态',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 8),
          Text('字幕轨道：${summary.trackLabel}'),
          Text('实际字幕格式：${summary.formatLabel}'),
          if (summary.declaredFormat != null)
            Text('服务端声明格式：${summary.declaredFormat!.toUpperCase()}'),
          Text('字幕阶段：${summary.stageLabel}'),
          Text('播放阶段：${summary.playbackStageLabel}'),
        ],
      ),
    ),
  );
}
