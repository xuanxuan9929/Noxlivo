/// Coordinates the three memory layers — fixed memory (system prompt),
/// cross-window recent life (SharedPreferences), and long-term memories
/// (per-assistant list, ranked by relevance) — without introducing a new
/// persistence format on top of [MemoryStore] / [CrossWindowMemoryStore].
///
/// Enhanced for Memory Lite V2: integrates [MemoryRecallRanker] with
/// multi-turn query building, weighted scoring, and dynamic budget filtering.
library;

import 'dart:math' as math;

import '../models/assistant.dart';
import '../models/assistant_memory.dart';
import 'memory_candidate.dart';
import 'memory_recall_ranker.dart';

class ThreeLayerMemoryPolicy {
  const ThreeLayerMemoryPolicy._();

  /// Rank [memories] for the given [query] and pick at most [limit] entries
  /// that fit within [maxChars] characters total.
  ///
  /// Integrates the Memory Lite V2 weighted ranking formula:
  /// score = keyword(0.40) + entity(0.25) + importance(0.15) + type(0.10) + recency(0.10).
  static List<AssistantMemory> selectLongTermMemories({
    required List<AssistantMemory> memories,
    required String query,
    required int limit,
    required int maxChars,
    List<String> recentHistory = const <String>[],
    double minThreshold = MemoryRecallRanker.defaultScoreThreshold,
  }) {
    if (query.trim().isEmpty ||
        memories.isEmpty ||
        limit <= 0 ||
        maxChars <= 0) {
      return const <AssistantMemory>[];
    }

    // 1. Build contextual multi-turn query
    final contextualQuery = MemoryRecallRanker.buildMultiTurnQuery(
      currentMessage: query,
      recentHistory: recentHistory,
    );

    // 2. Convert AssistantMemory items to MemoryCandidate wrappers for ranking
    final now = DateTime.now();
    final candidateWrappers = memories.map((m) {
      return MemoryCandidate(
        id: m.id.toString(),
        assistantId: m.assistantId,
        content: m.content,
        status: CandidateStatus.active,
        source: CandidateSource.manual,
        confidence: 1.0,
        importance: 0.70,
        createdAt: now,
        lastSeenAt: now,
      );
    }).toList();

    // 3. Rank and filter using MemoryRecallRanker
    final selectedCandidates = MemoryRecallRanker.rankAndFilter(
      candidates: candidateWrappers,
      query: contextualQuery,
      maxCount: limit,
      maxChars: maxChars,
      minThreshold: minThreshold,
      now: now,
    );

    if (selectedCandidates.isEmpty) {
      return const <AssistantMemory>[];
    }

    // 4. Map back to AssistantMemory instances
    final memoryMap = {for (final m in memories) m.id.toString(): m};
    final result = <AssistantMemory>[];
    for (final c in selectedCandidates) {
      final original = memoryMap[c.id];
      if (original != null) {
        result.add(original);
      }
    }
    return result;
  }

  /// Mirror of the Tumin decision table:
  /// - No `enableRecentChatsReference` → never inject.
  /// - 3-layer off → inject (compatibility path: 3-layer is the new master
  ///   switch; if it's off, fall back to legacy recent-chats behavior).
  /// - 3-layer on → only when fallback is on AND cross-window is off.
  static bool shouldInjectRecentChats(Assistant assistant) {
    if (!assistant.enableRecentChatsReference) return false;
    if (!assistant.enableThreeLayerMemory) return true;
    return assistant.useRecentChatsAsFallback &&
        !assistant.enableCrossWindowMemory;
  }
}
