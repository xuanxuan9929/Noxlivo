import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../../../core/providers/assistant_provider.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_checkbox.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../shared/widgets/snackbar.dart';
import '../../../theme/app_font_weights.dart';
import '../github_importer.dart';
import '../skill_importer.dart';
import '../skill_manager.dart';

class SkillsPage extends StatefulWidget {
  const SkillsPage({super.key, this.desktop = false});

  /// When true, renders as an embedded desktop settings pane (no Scaffold /
  /// AppBar / FAB, desktop-style cards) instead of a full mobile page.
  final bool desktop;

  @override
  State<SkillsPage> createState() => _SkillsPageState();
}

class _SkillsPageState extends State<SkillsPage> {
  List<SkillMetadata> _skills = const [];
  bool _loading = true;

  /// Tracks which category groups are expanded. All groups default to expanded.
  final Set<String> _collapsedGroups = {};

  @override
  void initState() {
    super.initState();
    SkillManager.initRoot().then((_) => _refresh());
  }

  Future<void> _refresh() async {
    final skills = await SkillManager.listSkills();
    if (!mounted) return;
    setState(() {
      _skills = skills;
      _loading = false;
    });
  }

  String? _extractNameFromFrontmatter(String content) {
    final parsed = SkillManager.parseFrontmatter(content);
    return parsed?.fields['name'];
  }

  String _localizeSaveError(SkillSaveError? error, AppLocalizations l10n) {
    if (error == null) return '';
    switch (error.code) {
      case 'invalid_frontmatter':
        return l10n.skillsInvalidFrontmatter;
      case 'name_invalid':
        return l10n.skillsNameInvalid;
      case 'name_missing':
        return l10n.skillsFrontmatterNameMissing;
      case 'name_mismatch':
        return l10n.skillsFrontmatterNameMismatch(
          error.params['frontmatterName'] ?? '',
          error.params['dirName'] ?? '',
        );
      case 'io_error':
        return l10n.skillsSaveFailed(error.params['detail'] ?? '');
      default:
        return l10n.skillsSaveFailed(error.params['detail'] ?? '');
    }
  }

  Future<void> _showAddDialog() async {
    final l10n = AppLocalizations.of(context)!;
    final controller = TextEditingController();

    final result = await showDialog<String>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            String? liveName;
            if (controller.text.trim().isNotEmpty) {
              final parsed = SkillManager.parseFrontmatter(controller.text);
              if (parsed != null) {
                liveName = parsed.fields['name'];
              }
            }

            return AlertDialog(
              title: Text(l10n.skillsImportManualTitle),
              content: SizedBox(
                width: 400,
                child: TextField(
                  controller: controller,
                  maxLines: 12,
                  decoration: InputDecoration(
                    hintText: l10n.skillsImportManualHint,
                    border: const OutlineInputBorder(),
                    contentPadding: const EdgeInsets.all(12),
                  ),
                  style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
                  onChanged: (_) => setDialogState(() {}),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: Text(MaterialLocalizations.of(ctx).cancelButtonLabel),
                ),
                FilledButton(
                  onPressed: liveName != null && liveName.isNotEmpty
                      ? () => Navigator.of(ctx).pop(controller.text)
                      : null,
                  child: Text(MaterialLocalizations.of(ctx).okButtonLabel),
                ),
              ],
            );
          },
        );
      },
    );

    if (result == null || result.isEmpty || !mounted) return;

    final name = _extractNameFromFrontmatter(result) ?? '';
    if (name.isEmpty) return;

    final error = await SkillManager.saveSkill(name: name, content: result);
    if (error != null) {
      if (!mounted) return;
      showAppSnackBar(context, message: _localizeSaveError(error, l10n));
      return;
    }
    await _refresh();
    await _promptEnableImported([name]);
  }

  Future<void> _showImportChoice() async {
    final l10n = AppLocalizations.of(context)!;
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(l10n.skillsImportChoiceTitle),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.of(ctx).pop('file'),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  const Icon(Lucide.FileText),
                  const SizedBox(width: 16),
                  Text(l10n.skillsImportFromFile),
                ],
              ),
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.of(ctx).pop('github'),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  const Icon(Lucide.Globe),
                  const SizedBox(width: 16),
                  Text(l10n.skillsImportFromGitHub),
                ],
              ),
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.of(ctx).pop('manual'),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  const Icon(Lucide.Plus),
                  const SizedBox(width: 16),
                  Text(l10n.skillsImportManualTitle),
                ],
              ),
            ),
          ),
        ],
      ),
    );
    if (choice == null || !mounted) return;
    if (choice == 'file') {
      await _importFromFile();
    } else if (choice == 'github') {
      await _importFromGitHub();
    } else if (choice == 'manual') {
      await _showAddDialog();
    }
  }

  Future<void> _importFromGitHub() async {
    final l10n = AppLocalizations.of(context)!;
    final controller = TextEditingController();

    final url = await showDialog<String>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            final text = controller.text.trim();
            final isValid = text.isEmpty || parseGitHubUrl(text) != null;

            return AlertDialog(
              title: Text(l10n.skillsGitHubImportTitle),
              content: SizedBox(
                width: 400,
                child: TextField(
                  controller: controller,
                  decoration: InputDecoration(
                    hintText: l10n.skillsGitHubUrlHint,
                    border: const OutlineInputBorder(),
                    errorText: isValid ? null : l10n.skillsGitHubUrlInvalid,
                  ),
                  style: const TextStyle(fontSize: 13),
                  onChanged: (_) => setDialogState(() {}),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: Text(MaterialLocalizations.of(ctx).cancelButtonLabel),
                ),
                FilledButton(
                  onPressed: text.isNotEmpty && isValid
                      ? () => Navigator.of(ctx).pop(text)
                      : null,
                  child: Text(MaterialLocalizations.of(ctx).okButtonLabel),
                ),
              ],
            );
          },
        );
      },
    );

    if (url == null || url.isEmpty || !mounted) return;

    final info = parseGitHubUrl(url);
    if (info == null) return;

    final zipFile = await downloadGitHubArchive(info);
    if (zipFile == null || !mounted) {
      if (mounted) {
        showAppSnackBar(
          context,
          message: l10n.skillsGitHubDownloadFailed,
          type: NotificationType.error,
        );
      }
      return;
    }

    try {
      final discovered = await SkillImporter.scanZipForSkills(
        zipFile,
        subPath: info.subPath,
        stripPrefix: info.stripPrefix,
      );

      if (discovered == null) {
        if (!mounted) return;
        showAppSnackBar(
          context,
          message: l10n.skillsGitHubDownloadFailed,
          type: NotificationType.error,
        );
        return;
      }

      if (discovered.isEmpty) {
        if (!mounted) return;
        showAppSnackBar(
          context,
          message: l10n.skillsImportFailed(0),
          type: NotificationType.error,
        );
        return;
      }

      List<DiscoveredSkill> selected;
      if (discovered.length == 1) {
        selected = discovered;
      } else {
        if (!mounted) return;
        final result = await _showSkillSelectionDialog(discovered);
        if (result == null || result.isEmpty) return;
        selected = result;
      }

      if (!mounted) return;
      await _importDiscoveredSkills(selected);
    } finally {
      try {
        await zipFile.delete();
      } catch (_) {}
    }
  }

  Future<List<DiscoveredSkill>?> _showSkillSelectionDialog(
    List<DiscoveredSkill> skills,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final selected = skills.length >= 5
        ? <int>{}
        : Set<int>.from(List.generate(skills.length, (i) => i));

    return showDialog<List<DiscoveredSkill>>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            final allSelected = selected.length == skills.length;
            return AlertDialog(
              title: Text(l10n.skillsGitHubSelectTitle),
              content: SizedBox(
                width: 400,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _TactileSelectAllRow(
                      label: allSelected
                          ? l10n.skillsDeselectAll
                          : l10n.skillsSelectAll,
                      checked: allSelected,
                      onTap: () {
                        setDialogState(() {
                          selected.clear();
                          if (!allSelected) {
                            selected.addAll(
                              List.generate(skills.length, (i) => i),
                            );
                          }
                        });
                      },
                    ),
                    const SizedBox(height: 4),
                    Flexible(
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: skills.length,
                        itemBuilder: (_, i) {
                          final skill = skills[i];
                          return ListTile(
                            leading: IosCheckbox(
                              value: selected.contains(i),
                              onChanged: (v) {
                                setDialogState(() {
                                  if (v) {
                                    selected.add(i);
                                  } else {
                                    selected.remove(i);
                                  }
                                });
                              },
                            ),
                            title: Text(skill.name),
                            subtitle: skill.description.isNotEmpty
                                ? Text(
                                    skill.description,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  )
                                : null,
                            onTap: () {
                              setDialogState(() {
                                if (selected.contains(i)) {
                                  selected.remove(i);
                                } else {
                                  selected.add(i);
                                }
                              });
                            },
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: Text(MaterialLocalizations.of(ctx).cancelButtonLabel),
                ),
                FilledButton(
                  onPressed: selected.isNotEmpty
                      ? () => Navigator.of(
                          ctx,
                        ).pop(selected.map((i) => skills[i]).toList())
                      : null,
                  child: Text(MaterialLocalizations.of(ctx).okButtonLabel),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _promptEnableImported(List<String> names) async {
    if (names.isEmpty || !mounted) return;
    final l10n = AppLocalizations.of(context)!;
    final assistant = context.read<AssistantProvider>().currentAssistant;
    if (assistant == null) return;

    final enabled = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.skillsEnableImportedTitle),
        content: Text(
          l10n.skillsEnableImportedMessage(names.length, assistant.name),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.skillsEnableImportedDismiss),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.skillsEnableImportedAction),
          ),
        ],
      ),
    );
    if (enabled != true || !mounted) return;

    final ids = {...assistant.skillIds, ...names};
    await context.read<AssistantProvider>().updateAssistant(
      assistant.copyWith(skillIds: ids.toList(growable: false)),
    );
  }

  Future<void> _importDiscoveredSkills(List<DiscoveredSkill> skills) async {
    final result = await SkillImporter.importSkills(skills);

    if (!mounted) return;
    final l10n = AppLocalizations.of(context)!;
    if (result.imported > 0) {
      showAppSnackBar(
        context,
        message: l10n.skillsImportSuccess(result.imported),
      );
    }
    if (result.failed > 0) {
      showAppSnackBar(
        context,
        message: l10n.skillsImportFailed(result.failed),
        type: NotificationType.error,
      );
    }
    await _refresh();
    await _promptEnableImported(result.importedNames);
  }

  Future<void> _importFromFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      allowMultiple: false,
    );
    if (result == null || result.files.isEmpty) return;

    final file = result.files.first;
    if (file.path == null) return;

    final path = file.path!;
    final ext = p.extension(path).toLowerCase();

    if (ext == '.zip') {
      final discovered = await SkillImporter.scanZipForSkills(File(path));
      if (discovered == null || discovered.isEmpty) {
        if (!mounted) return;
        final l10n = AppLocalizations.of(context)!;
        showAppSnackBar(
          context,
          message: l10n.skillsImportFailed(0),
          type: NotificationType.error,
        );
        return;
      }
      await _importDiscoveredSkills(discovered);
    } else {
      int imported = 0;
      int failed = 0;
      final importedNames = <String>[];
      try {
        final content = await File(path).readAsString();
        final name = _extractNameFromFrontmatter(content);
        if (name == null) {
          failed++;
        } else {
          final error = await SkillManager.saveSkill(
            name: name,
            content: content,
          );
          if (error != null) {
            failed++;
          } else {
            imported++;
            importedNames.add(name);
          }
        }
      } catch (_) {
        failed++;
      }

      if (!mounted) return;
      final l10n = AppLocalizations.of(context)!;
      if (imported > 0) {
        showAppSnackBar(context, message: l10n.skillsImportSuccess(imported));
      }
      if (failed > 0) {
        showAppSnackBar(
          context,
          message: l10n.skillsImportFailed(failed),
          type: NotificationType.error,
        );
      }
      await _refresh();
      await _promptEnableImported(importedNames);
    }
  }

  Future<void> _deleteSkill(String name) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.skillsDeleteConfirmTitle),
        content: Text(l10n.skillsDeleteConfirmMessage(name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(MaterialLocalizations.of(ctx).cancelButtonLabel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            child: Text(l10n.skillsDeleteConfirmDeleteButton),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    await SkillManager.deleteSkill(name);
    if (mounted) {
      context.read<AssistantProvider>().removeSkillFromAllAssistants(name);
    }
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;

    if (widget.desktop) {
      return _buildDesktop(l10n, cs);
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.skillsTitle),
        actions: [
          IconButton(
            icon: const Icon(Lucide.Download),
            tooltip: l10n.skillsImportChoiceTitle,
            onPressed: _showImportChoice,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _skills.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  l10n.skillsEmptyMessage,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14,
                    color: cs.onSurface.withValues(alpha: 0.5),
                  ),
                ),
              ),
            )
          : RefreshIndicator(
              onRefresh: () async => _refresh(),
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: _buildSkillGroups(),
              ),
            ),
    );
  }

  Widget _buildDesktop(AppLocalizations l10n, ColorScheme cs) {
    return Container(
      alignment: Alignment.topCenter,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 960),
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  padding: EdgeInsets.zero,
                  children: [
                    _buildDesktopHeader(l10n, cs),
                    const SizedBox(height: 8),
                    if (_skills.isEmpty)
                      _buildDesktopEmpty(l10n, cs)
                    else
                      ..._buildSkillGroups(desktop: true),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _buildDesktopHeader(AppLocalizations l10n, ColorScheme cs) {
    return SizedBox(
      height: 36,
      child: Row(
        children: [
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                l10n.skillsTitle,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: AppFontWeights.regular,
                  color: cs.onSurface.withValues(alpha: 0.9),
                ),
              ),
            ),
          ),
          Tooltip(
            message: l10n.skillsImportChoiceTitle,
            child: IosIconButton(
              icon: Lucide.Import,
              size: 18,
              onTap: _showImportChoice,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDesktopEmpty(AppLocalizations l10n, ColorScheme cs) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 32),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Lucide.BookOpen,
              size: 56,
              color: cs.onSurface.withValues(alpha: 0.28),
            ),
            const SizedBox(height: 12),
            Text(
              l10n.skillsEmptyMessage,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: cs.onSurface.withValues(alpha: 0.65),
                fontSize: 14,
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildSkillGroups({bool desktop = false}) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final groups = groupSkillsByCategory(_skills);

    // When there is only one group, skip the collapsible wrapper and render
    // the skills directly to avoid unnecessary nesting.
    if (groups.length == 1) {
      final (_, skills) = groups.first;
      return [
        for (final skill in skills)
          desktop
              ? _buildDesktopSkillCard(l10n, cs, skill)
              : _buildMobileSkillCard(l10n, cs, skill),
      ];
    }

    return [
      for (final (group, skills) in groups)
        _CollapsibleCategoryGroup(
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
              desktop
                  ? _buildDesktopSkillCard(l10n, cs, skill)
                  : _buildMobileSkillCard(l10n, cs, skill),
          ],
        ),
    ];
  }

  Widget _buildMobileSkillCard(
    AppLocalizations l10n,
    ColorScheme cs,
    SkillMetadata skill,
  ) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Icon(Lucide.BookOpen, color: cs.primary),
        title: Text(
          skill.name,
          style: TextStyle(fontWeight: AppFontWeights.semibold),
        ),
        subtitle: skill.description.isNotEmpty
            ? Text(
                skill.description,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              )
            : null,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 120),
              child: _CategoryTag(
                category: skill.category,
                label: skill.category ?? l10n.skillsUncategorizedGroup,
                onTap: () => _editCategory(skill),
              ),
            ),
            IconButton(
              icon: const Icon(Lucide.Trash2),
              color: cs.error,
              onPressed: () => _deleteSkill(skill.name),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDesktopSkillCard(
    AppLocalizations l10n,
    ColorScheme cs,
    SkillMetadata skill,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: IosCardPress(
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            children: [
              Icon(Lucide.BookOpen, size: 20, color: cs.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      skill.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: AppFontWeights.semibold,
                      ),
                    ),
                    if (skill.description.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        skill.description,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          color: cs.onSurface.withValues(alpha: 0.75),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 120),
                child: _CategoryTag(
                  category: skill.category,
                  label: skill.category ?? l10n.skillsUncategorizedGroup,
                  onTap: () => _editCategory(skill),
                ),
              ),
              const SizedBox(width: 4),
              Tooltip(
                message: l10n.skillsDeleteConfirmDeleteButton,
                child: IosIconButton(
                  icon: Lucide.Trash2,
                  size: 18,
                  color: cs.error,
                  onTap: () => _deleteSkill(skill.name),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _editCategory(SkillMetadata skill) async {
    final l10n = AppLocalizations.of(context)!;
    final controller = TextEditingController(text: skill.category ?? '');
    final known =
        _skills
            .map((s) => s.category)
            .whereType<String>()
            .where((c) => c.isNotEmpty)
            .toSet()
            .toList()
          ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

    final result = await showDialog<String>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return AlertDialog(
              title: Text(l10n.skillsEditCategoryTitle),
              content: SizedBox(
                width: 400,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      controller: controller,
                      autofocus: true,
                      decoration: InputDecoration(
                        hintText: l10n.skillsCategoryHint,
                        border: const OutlineInputBorder(),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                      ),
                      style: const TextStyle(fontSize: 13),
                      onChanged: (_) => setDialogState(() {}),
                      onSubmitted: (_) =>
                          Navigator.of(ctx).pop(controller.text.trim()),
                    ),
                    if (known.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final c in known)
                            _CategorySuggestionPill(
                              label: c,
                              onTap: () {
                                controller.text = c;
                                setDialogState(() {});
                              },
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(''),
                  child: Text(l10n.skillsCategoryClear),
                ),
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: Text(MaterialLocalizations.of(ctx).cancelButtonLabel),
                ),
                FilledButton(
                  onPressed: () =>
                      Navigator.of(ctx).pop(controller.text.trim()),
                  child: Text(MaterialLocalizations.of(ctx).okButtonLabel),
                ),
              ],
            );
          },
        );
      },
    );

    if (result == null || !mounted) return;
    final newCategory = result.trim();
    if (newCategory == (skill.category ?? '')) return;
    final error = await SkillManager.updateCategory(
      skill.name,
      newCategory.isEmpty ? null : newCategory,
    );
    if (error != null) {
      if (!mounted) return;
      showAppSnackBar(context, message: _localizeSaveError(error, l10n));
      return;
    }
    await _refresh();
  }
}

/// A collapsible group header that wraps skills belonging to the same category.
///
/// Tapping the header expands or collapses the group. The header shows the
/// category name, skill count badge, and a rotation-animated chevron icon.
class _CollapsibleCategoryGroup extends StatelessWidget {
  const _CollapsibleCategoryGroup({
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
        key: PageStorageKey<String>('skill_group_$groupKey'),
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

class _CategoryTag extends StatelessWidget {
  const _CategoryTag({
    required this.category,
    required this.label,
    required this.onTap,
  });
  final String? category;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final hasCategory = category != null && category!.isNotEmpty;
    final fg = hasCategory ? cs.primary : cs.onSurface.withValues(alpha: 0.45);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: hasCategory
              ? cs.primary.withValues(alpha: 0.08)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: hasCategory
                ? cs.primary.withValues(alpha: 0.3)
                : cs.outlineVariant.withValues(alpha: 0.5),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              hasCategory ? Lucide.Folder : Lucide.FolderOpen,
              size: 11,
              color: fg,
            ),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: fg),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CategorySuggestionPill extends StatelessWidget {
  const _CategorySuggestionPill({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: cs.primary.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: cs.primary.withValues(alpha: 0.25)),
        ),
        child: Text(label, style: TextStyle(fontSize: 12, color: cs.primary)),
      ),
    );
  }
}

class _TactileSelectAllRow extends StatelessWidget {
  const _TactileSelectAllRow({
    required this.label,
    required this.checked,
    required this.onTap,
  });
  final String label;
  final bool checked;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        child: Row(
          children: [
            IosCheckbox(value: checked, onChanged: (_) => onTap()),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: TextStyle(fontSize: 14, color: cs.onSurface),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
