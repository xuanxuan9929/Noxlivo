import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/models/assistant.dart';
import '../../../core/providers/assistant_provider.dart';
import '../../../core/services/haptics.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_switch.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../theme/app_font_weights.dart';
import '../pages/skills_page.dart';
import '../skill_manager.dart';

/// Bottom sheet for toggling the current assistant's skills.
///
/// Mirrors the instruction-injection sheet entry point so skills are as
/// discoverable as instruction prompts from the chat input bar.
class SkillsSheet extends StatefulWidget {
  const SkillsSheet({super.key, required this.assistantId});

  final String? assistantId;

  @override
  State<SkillsSheet> createState() => _SkillsSheetState();
}

class _SkillsSheetState extends State<SkillsSheet> {
  List<SkillMetadata> _skills = const [];
  bool _loading = true;
  final Set<String> _collapsedGroups = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final skills = await SkillManager.listSkills();
    if (!mounted) return;
    setState(() {
      _skills = skills;
      _loading = false;
    });
  }

  List<Widget> _buildSheetGroups(
    Assistant assistant,
    AppLocalizations l10n,
    ColorScheme cs,
  ) {
    final groups = groupSkillsByCategory(_skills);

    // Single group: skip the collapsible wrapper.
    if (groups.length == 1) {
      final (_, skills) = groups.first;
      return [
        for (final skill in skills)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _SkillSheetRow(
              name: skill.name,
              enabled: assistant.skillIds.contains(skill.name),
              onChanged: (v) => _toggle(assistant, skill.name, v),
            ),
          ),
      ];
    }

    return [
      for (final (group, skills) in groups)
        _SheetCollapsibleGroup(
          groupKey: group ?? '',
          title: group ?? l10n.skillsUncategorizedGroup,
          count: skills.length,
          initiallyExpanded: !_collapsedGroups.contains(group ?? ''),
          onExpansionChanged: (expanded) {
            setState(() {
              if (expanded) {
                _collapsedGroups.remove(group ?? '');
              } else {
                _collapsedGroups.add(group ?? '');
              }
            });
          },
          children: [
            for (final skill in skills)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _SkillSheetRow(
                  name: skill.name,
                  enabled: assistant.skillIds.contains(skill.name),
                  onChanged: (v) => _toggle(assistant, skill.name, v),
                ),
              ),
          ],
        ),
    ];
  }

  void _toggle(Assistant assistant, String name, bool value) {
    final ids = assistant.skillIds.toSet();
    if (value) {
      ids.add(name);
    } else {
      ids.remove(name);
    }
    context.read<AssistantProvider>().updateAssistant(
      assistant.copyWith(skillIds: ids.toList(growable: false)),
    );
  }

  bool _isAllSelected(Assistant assistant) =>
      _skills.isNotEmpty &&
      _skills.every((s) => assistant.skillIds.contains(s.name));

  void _toggleSelectAll(Assistant assistant) {
    if (_isAllSelected(assistant)) {
      context.read<AssistantProvider>().updateAssistant(
        assistant.copyWith(skillIds: const <String>[]),
      );
    } else {
      final ids = assistant.skillIds.toSet()
        ..addAll(_skills.map((s) => s.name));
      context.read<AssistantProvider>().updateAssistant(
        assistant.copyWith(skillIds: ids.toList(growable: false)),
      );
    }
  }

  void _openManagePage() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const SkillsPage()));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final ap = context.watch<AssistantProvider>();
    final assistant = widget.assistantId != null
        ? ap.getById(widget.assistantId!)
        : ap.currentAssistant;

    return SafeArea(
      top: false,
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.5,
        maxChildSize: 0.85,
        minChildSize: 0.45,
        builder: (ctx, controller) {
          return Column(
            children: [
              _SheetTopBar(
                title: l10n.skillsTitle,
                onBack: () => Navigator.of(ctx).maybePop(),
                onManage: _openManagePage,
                showSelectAll: _skills.isNotEmpty && assistant != null,
                allSelected: assistant != null && _isAllSelected(assistant),
                onSelectAll: () {
                  final a = assistant;
                  if (a != null) _toggleSelectAll(a);
                },
              ),
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : _skills.isEmpty
                    ? _SkillsEmptyState(onImport: _openManagePage)
                    : assistant == null
                    ? Center(
                        child: Text(
                          l10n.assistantEditPageNotFound,
                          style: TextStyle(
                            color: cs.onSurface.withValues(alpha: 0.6),
                          ),
                        ),
                      )
                    : ListView(
                        controller: controller,
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                        children: _buildSheetGroups(assistant, l10n, cs),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _SheetCollapsibleGroup extends StatelessWidget {
  const _SheetCollapsibleGroup({
    required this.groupKey,
    required this.title,
    required this.count,
    required this.initiallyExpanded,
    required this.onExpansionChanged,
    required this.children,
  });

  final String groupKey;
  final String title;
  final int count;
  final bool initiallyExpanded;
  final ValueChanged<bool> onExpansionChanged;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        key: PageStorageKey<String>('skill_sheet_group_$groupKey'),
        initiallyExpanded: initiallyExpanded,
        onExpansionChanged: onExpansionChanged,
        tilePadding: const EdgeInsets.symmetric(horizontal: 4),
        childrenPadding: EdgeInsets.zero,
        shape: const Border(),
        collapsedShape: const Border(),
        title: Row(
          children: [
            Text(
              title,
              style: TextStyle(
                fontSize: 13,
                fontWeight: AppFontWeights.semibold,
                color: cs.onSurface.withValues(alpha: 0.65),
              ),
            ),
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: cs.primary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '$count',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: AppFontWeights.medium,
                  color: cs.primary,
                ),
              ),
            ),
          ],
        ),
        children: children,
      ),
    );
  }
}

class _SheetTopBar extends StatelessWidget {
  const _SheetTopBar({
    required this.title,
    required this.onBack,
    required this.onManage,
    required this.showSelectAll,
    required this.allSelected,
    required this.onSelectAll,
  });

  final String title;
  final VoidCallback onBack;
  final VoidCallback onManage;
  final bool showSelectAll;
  final bool allSelected;
  final VoidCallback onSelectAll;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      height: 52,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            _NavIconButton(icon: Lucide.ArrowLeft, onTap: onBack),
            Expanded(
              child: Center(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: AppFontWeights.emphasis,
                    color: cs.onSurface,
                  ),
                ),
              ),
            ),
            if (showSelectAll)
              Tooltip(
                message: allSelected
                    ? l10n.skillsClearAll
                    : l10n.skillsSelectAll,
                child: _NavIconButton(
                  icon: Lucide.ListChecks,
                  onTap: onSelectAll,
                  color: allSelected ? cs.primary : cs.onSurface,
                ),
              ),
            Tooltip(
              message: l10n.skillsSheetManageAction,
              child: _NavIconButton(icon: Lucide.BookOpen, onTap: onManage),
            ),
          ],
        ),
      ),
    );
  }
}

class _NavIconButton extends StatelessWidget {
  const _NavIconButton({required this.icon, required this.onTap, this.color});

  final IconData icon;
  final VoidCallback onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      width: 40,
      height: 40,
      child: IosCardPress(
        borderRadius: BorderRadius.circular(12),
        baseColor: Colors.transparent,
        duration: const Duration(milliseconds: 200),
        padding: EdgeInsets.zero,
        onTap: () {
          Haptics.light();
          onTap();
        },
        child: Center(
          child: Icon(icon, size: 20, color: color ?? cs.onSurface),
        ),
      ),
    );
  }
}

class _SkillSheetRow extends StatelessWidget {
  const _SkillSheetRow({
    required this.name,
    required this.enabled,
    required this.onChanged,
  });

  final String name;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final iconColor = enabled
        ? cs.primary
        : cs.onSurface.withValues(alpha: 0.7);
    return IosCardPress(
      borderRadius: BorderRadius.circular(14),
      baseColor: cs.surface,
      duration: const Duration(milliseconds: 260),
      onTap: () => onChanged(!enabled),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          Icon(Lucide.BookOpen, size: 18, color: iconColor),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 15,
                fontWeight: AppFontWeights.medium,
                color: cs.onSurface,
              ),
            ),
          ),
          const SizedBox(width: 10),
          IosSwitch(value: enabled, onChanged: onChanged),
        ],
      ),
    );
  }
}

class _SkillsEmptyState extends StatelessWidget {
  const _SkillsEmptyState({required this.onImport});

  final VoidCallback onImport;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Lucide.BookOpen,
              size: 36,
              color: cs.onSurface.withValues(alpha: 0.3),
            ),
            const SizedBox(height: 12),
            Text(
              l10n.skillsEmptyMessage,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13.5,
                color: cs.onSurface.withValues(alpha: 0.6),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onImport,
              icon: const Icon(Lucide.Download, size: 16),
              label: Text(l10n.skillsSheetImportAction),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shows the skills bottom sheet.
///
/// This is a convenience function to show the sheet with proper styling.
Future<void> showSkillsSheet(
  BuildContext context, {
  required String? assistantId,
}) async {
  final cs = Theme.of(context).colorScheme;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: cs.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (sheetCtx) {
      return SkillsSheet(assistantId: assistantId);
    },
  );
}
