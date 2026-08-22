/// Memory de-duplication and conflict detector.
///
/// Implements PR 3 of the Memory Lite V2 specification:
/// - High similarity (> 0.80): merge hit counts, update lastSeenAt.
/// - Structured key-value conflict: mark old memory as `superseded`, set new memory as `active`.
/// - LLM/rule based conflict resolution.
library;

import 'dart:math' as math;
import 'memory_candidate.dart';
import 'memory_diagnostic_logger.dart';

enum MergeAction {
  added,
  mergedDuplicate,
  supersededOldKey,
}

class MemoryMergeResult {
  final MergeAction action;
  final MemoryCandidate resultCandidate;
  final MemoryCandidate? supersededCandidate;
  final String? reason;

  const MemoryMergeResult({
    required this.action,
    required this.resultCandidate,
    this.supersededCandidate,
    this.reason,
  });
}

class MemoryMergeDetector {
  const MemoryMergeDetector._();

  static const double duplicateSimilarityThreshold = 0.80;

  /// Pure text token-based Jaccard similarity (0.0 to 1.0).
  static double calculateSimilarity(String s1, String s2) {
    final t1 = _tokenize(s1);
    final t2 = _tokenize(s2);
    if (t1.isEmpty && t2.isEmpty) return 1.0;
    if (t1.isEmpty || t2.isEmpty) return 0.0;

    final set1 = t1.toSet();
    final set2 = t2.toSet();

    final intersection = set1.intersection(set2).length;
    final union = set1.union(set2).length;

    return union == 0 ? 0.0 : intersection / union;
  }

  /// Process incoming memory candidate against the existing pool.
  static MemoryMergeResult process({
    required MemoryCandidate incoming,
    required List<MemoryCandidate> existingPool,
  }) {
    // 1. Check structured key-value conflict first
    if (incoming.key != null && incoming.key!.isNotEmpty) {
      for (final existing in existingPool) {
        if (existing.status != CandidateStatus.rejected &&
            existing.status != CandidateStatus.superseded &&
            existing.key == incoming.key) {
          // If value is different, old is superseded, incoming is active
          if (existing.value != incoming.value) {
            final oldSuperseded = existing.copyWith(
              status: CandidateStatus.superseded,
              lastSeenAt: DateTime.now(),
            );
            final newActive = incoming.copyWith(
              status: CandidateStatus.active,
              confidence: math.max(incoming.confidence, 0.90),
            );

            MemoryDiagnosticLogger.instance.logConflict(
              action: 'superseded_old_key',
              newContent: '${newActive.key}=${newActive.value}',
              oldContent: '${existing.key}=${existing.value}',
              reason: 'Key [${incoming.key}] updated with new value',
            );

            return MemoryMergeResult(
              action: MergeAction.supersededOldKey,
              resultCandidate: newActive,
              supersededCandidate: oldSuperseded,
              reason: 'Structured key [${incoming.key}] replaced old value',
            );
          } else {
            // Same key and same value -> duplicate hit
            final merged = existing.recordHit(customBoost: 0.10);
            MemoryDiagnosticLogger.instance.logConflict(
              action: 'merged_duplicate',
              newContent: incoming.content,
              oldContent: existing.content,
              reason: 'Same key and value duplicate',
            );
            return MemoryMergeResult(
              action: MergeAction.mergedDuplicate,
              resultCandidate: merged,
              reason: 'Duplicate key/value merged',
            );
          }
        }
      }
    }

    // 2. Check text-level similarity for un-keyed items
    for (final existing in existingPool) {
      if (existing.status == CandidateStatus.rejected ||
          existing.status == CandidateStatus.superseded) {
        continue;
      }
      final sim = calculateSimilarity(incoming.content, existing.content);
      if (sim >= duplicateSimilarityThreshold) {
        final merged = existing.recordHit(
          customBoost: 0.15,
          isStrongConfirm: incoming.source == CandidateSource.userExplicit,
        );

        MemoryDiagnosticLogger.instance.logConflict(
          action: 'merged_duplicate',
          newContent: incoming.content,
          oldContent: existing.content,
          reason: 'High similarity ($sim >= $duplicateSimilarityThreshold)',
        );

        return MemoryMergeResult(
          action: MergeAction.mergedDuplicate,
          resultCandidate: merged,
          reason: 'High text similarity ($sim) merged',
        );
      }
    }

    // 3. Brand new fact
    return MemoryMergeResult(
      action: MergeAction.added,
      resultCandidate: incoming,
      reason: 'No duplicate or conflict found; added as new',
    );
  }

  static List<String> _tokenize(String text) {
    final clean = text.trim().toLowerCase();
    if (clean.isEmpty) return const <String>[];

    final tokens = <String>[];
    final words = clean.split(RegExp(r'[\s,，.。!！?？:：;；"“”\(\)\[\]]+'));
    for (final w in words) {
      if (w.isEmpty) continue;
      // Latin word
      if (RegExp(r'^[a-z0-9_-]+$').hasMatch(w)) {
        tokens.add(w);
      } else {
        // CJK character grams
        for (var i = 0; i < w.length; i++) {
          tokens.add(w[i]);
          if (i + 1 < w.length) {
            tokens.add(w.substring(i, i + 2));
          }
        }
      }
    }
    return tokens;
  }
}
