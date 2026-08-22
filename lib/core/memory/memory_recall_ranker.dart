/// Memory recall ranker for V1 (non-embedding) weighted scoring.
///
/// Implements PR 4 & PR 5 of the Memory Lite V2 specification:
/// - Contextual multi-turn recall query builder (current message + recent 2-4 turns).
/// - Weighted scoring: keyword(0.40) + entity(0.25) + importance(0.15) + type(0.10) + recency(0.10).
/// - Dynamic thresholding & budget clipping (permits 0 items if score < threshold).
library;

import 'dart:math' as math;
import 'memory_candidate.dart';
import 'memory_diagnostic_logger.dart';

class ScoredMemory {
  final MemoryCandidate candidate;
  final double score;
  final double keywordScore;
  final double entityScore;
  final double importanceScore;
  final double typeScore;
  final double recencyScore;

  const ScoredMemory({
    required this.candidate,
    required this.score,
    required this.keywordScore,
    required this.entityScore,
    required this.importanceScore,
    required this.typeScore,
    required this.recencyScore,
  });

  Map<String, dynamic> toDiagnosticMap({required bool selected}) => {
        'id': candidate.id,
        'content': candidate.content,
        'status': candidate.status.name,
        'finalScore': double.parse(score.toStringAsFixed(3)),
        'breakdown': {
          'keyword': double.parse(keywordScore.toStringAsFixed(3)),
          'entity': double.parse(entityScore.toStringAsFixed(3)),
          'importance': double.parse(importanceScore.toStringAsFixed(3)),
          'type': double.parse(typeScore.toStringAsFixed(3)),
          'recency': double.parse(recencyScore.toStringAsFixed(3)),
        },
        'decision': selected ? 'SELECTED' : 'REJECTED',
      };
}

class MemoryRecallRanker {
  const MemoryRecallRanker._();

  static const double defaultScoreThreshold = 0.28;

  /// Builds a combined recall query from current message + recent 2~4 turns.
  static String buildMultiTurnQuery({
    required String currentMessage,
    List<String> recentHistory = const <String>[],
  }) {
    final cleanCurrent = currentMessage.trim();
    if (recentHistory.isEmpty) return cleanCurrent;

    // Take up to 4 recent messages
    final tail = recentHistory.length > 4
        ? recentHistory.sublist(recentHistory.length - 4)
        : recentHistory;

    final queryParts = <String>[cleanCurrent];
    for (final msg in tail) {
      final terms = _extractSignificantTerms(msg);
      if (terms.isNotEmpty) {
        queryParts.add(terms.join(' '));
      }
    }
    return queryParts.join(' ');
  }

  /// Ranks [candidates] against [query] using the V1 weighted formula.
  static List<MemoryCandidate> rankAndFilter({
    required List<MemoryCandidate> candidates,
    required String query,
    int maxCount = 4,
    int maxChars = 3000,
    double minThreshold = defaultScoreThreshold,
    DateTime? now,
  }) {
    if (query.trim().isEmpty || candidates.isEmpty || maxCount <= 0 || maxChars <= 0) {
      return const <MemoryCandidate>[];
    }

    final queryTokens = _tokenize(query);
    final queryEntities = _extractEntities(query);
    final currentTime = now ?? DateTime.now();

    final scoredList = <ScoredMemory>[];

    for (final item in candidates) {
      // Only active items are recalled by default
      if (item.status != CandidateStatus.active) continue;

      final contentTokens = _tokenize(item.content);
      final contentEntities = _extractEntities(item.content);

      // 1. Keyword match (0.40)
      var overlap = 0;
      for (final q in queryTokens) {
        if (contentTokens.contains(q)) overlap++;
      }
      final keywordScore = queryTokens.isEmpty
          ? 0.0
          : math.min(1.0, overlap / math.max(1, queryTokens.length * 0.5));

      // 2. Entity match (0.25)
      var entityOverlap = 0;
      for (final e in queryEntities) {
        if (contentEntities.contains(e) || item.content.toLowerCase().contains(e)) {
          entityOverlap++;
        }
      }
      final entityScore = queryEntities.isEmpty
          ? 0.0
          : math.min(1.0, entityOverlap / queryEntities.length);

      // 3. Importance (0.15)
      final importanceScore = item.importance.clamp(0.0, 1.0);

      // 4. Type weight (0.10)
      final typeScore = _typeWeight(item.type);

      // 5. Recency (0.10) - decayed over 30 days
      final ageHours = currentTime.difference(item.lastSeenAt).inHours;
      final recencyScore = math.exp(-ageHours / (24.0 * 14.0)); // half-life ~14 days

      // Weighted combination
      final finalScore = (keywordScore * 0.40) +
          (entityScore * 0.25) +
          (importanceScore * 0.15) +
          (typeScore * 0.10) +
          (recencyScore * 0.10);

      scoredList.add(
        ScoredMemory(
          candidate: item,
          score: finalScore,
          keywordScore: keywordScore,
          entityScore: entityScore,
          importanceScore: importanceScore,
          typeScore: typeScore,
          recencyScore: recencyScore,
        ),
      );
    }

    // Sort descending by score, tie-break by recency
    scoredList.sort((a, b) {
      final cmp = b.score.compareTo(a.score);
      if (cmp != 0) return cmp;
      return b.candidate.lastSeenAt.compareTo(a.candidate.lastSeenAt);
    });

    final selected = <MemoryCandidate>[];
    final diagnosticItems = <Map<String, dynamic>>[];
    var accumulatedChars = 0;

    for (final entry in scoredList) {
      final isOverThreshold = entry.score >= minThreshold;
      final fitsBudget = (accumulatedChars + entry.candidate.content.length) <= maxChars;
      final underCountLimit = selected.length < maxCount;

      final isSelected = isOverThreshold && fitsBudget && underCountLimit;
      if (isSelected) {
        selected.add(entry.candidate);
        accumulatedChars += entry.candidate.content.length;
      }
      diagnosticItems.add(entry.toDiagnosticMap(selected: isSelected));
    }

    MemoryDiagnosticLogger.instance.logRecall(
      query: query,
      candidatePoolSize: candidates.length,
      selectedCount: selected.length,
      injectedChars: accumulatedChars,
      scoredItems: diagnosticItems,
    );

    return selected;
  }

  static double _typeWeight(String? type) {
    switch (type) {
      case 'preference':
      case 'profile':
      case 'manual':
        return 1.0;
      case 'instruction':
      case 'fact':
        return 0.85;
      case 'phase_summary':
      case 'daily_summary':
        return 0.70;
      default:
        return 0.50;
    }
  }

  static List<String> _tokenize(String text) {
    final clean = text.trim().toLowerCase();
    if (clean.isEmpty) return const <String>[];
    final tokens = <String>[];
    final words = clean.split(RegExp(r'[\s,，.。!！?？:：;；"“”\(\)\[\]]+'));
    for (final w in words) {
      if (w.isEmpty) continue;
      if (RegExp(r'^[a-z0-9_-]+$').hasMatch(w)) {
        tokens.add(w);
      } else {
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

  static List<String> _extractEntities(String text) {
    final entities = <String>[];
    // Simple regex entity heuristics (quoted terms, capitalized terms, brackets)
    final matches = RegExp(r'[“"「【](.+?)[”"」】]').allMatches(text);
    for (final m in matches) {
      final val = m.group(1)?.trim();
      if (val != null && val.isNotEmpty) entities.add(val.toLowerCase());
    }
    return entities;
  }

  static List<String> _extractSignificantTerms(String text) {
    final tokens = _tokenize(text);
    // Remove basic stop single-char particles
    const stopTokens = {'的', '了', '是', '在', '我', '你', '他', '她', '它', '吗', '呢', '吧', '啊'};
    return tokens.where((t) => !stopTokens.contains(t) && t.length > 1).toList();
  }
}
