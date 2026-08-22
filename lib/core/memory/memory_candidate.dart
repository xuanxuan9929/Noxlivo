/// Candidate memory model and state machine.
///
/// Implements PR 2 of the Memory Lite V2 specification:
/// Manages lightweight candidate memories, confidence decay/boost,
/// hit count accumulation, and promotion to active long-term memories.
library;

import 'dart:math' as math;
import 'memory_diagnostic_logger.dart';

enum CandidateStatus {
  candidate,
  active,
  superseded,
  rejected,
}

enum CandidateSource {
  userExplicit,
  aiInferred,
  repeatedPattern,
  manual,
}

class MemoryCandidate {
  final String id;
  final String assistantId;
  final String content;
  final CandidateStatus status;
  final CandidateSource source;
  final double confidence;
  final double importance;
  final int hitCount;
  final String? type; // 'preference' | 'fact' | 'instruction'
  final String? key;
  final String? value;
  final DateTime createdAt;
  final DateTime lastSeenAt;

  const MemoryCandidate({
    required this.id,
    required this.assistantId,
    required this.content,
    this.status = CandidateStatus.candidate,
    this.source = CandidateSource.aiInferred,
    this.confidence = 0.60,
    this.importance = 0.50,
    this.hitCount = 1,
    this.type,
    this.key,
    this.value,
    required this.createdAt,
    required this.lastSeenAt,
  });

  static const double promotionThreshold = 0.82;
  static const double defaultHitBoost = 0.15;
  static const double strongConfirmBoost = 0.20;

  /// Returns a copy with incremented hit count and boosted confidence.
  MemoryCandidate recordHit({
    double? customBoost,
    bool isStrongConfirm = false,
    DateTime? now,
  }) {
    final boost = customBoost ??
        (isStrongConfirm ? strongConfirmBoost : defaultHitBoost);
    final newConf = math.min(1.0, confidence + boost);
    final newCount = hitCount + 1;
    final currentTime = now ?? DateTime.now();

    final isPromoted = newConf >= promotionThreshold &&
        status == CandidateStatus.candidate;
    final newStatus = isPromoted ? CandidateStatus.active : status;

    final updated = copyWith(
      confidence: newConf,
      hitCount: newCount,
      lastSeenAt: currentTime,
      status: newStatus,
    );

    MemoryDiagnosticLogger.instance.logCandidate(
      candidateId: id,
      action: isPromoted ? 'promoted' : 'hit_boost',
      hitCount: newCount,
      confidence: newConf,
      content: content,
    );

    return updated;
  }

  /// Check whether candidate is ready for active status.
  bool get isReadyForActive => confidence >= promotionThreshold;

  MemoryCandidate copyWith({
    String? id,
    String? assistantId,
    String? content,
    CandidateStatus? status,
    CandidateSource? source,
    double? confidence,
    double? importance,
    int? hitCount,
    String? type,
    String? key,
    String? value,
    DateTime? createdAt,
    DateTime? lastSeenAt,
  }) {
    return MemoryCandidate(
      id: id ?? this.id,
      assistantId: assistantId ?? this.assistantId,
      content: content ?? this.content,
      status: status ?? this.status,
      source: source ?? this.source,
      confidence: confidence ?? this.confidence,
      importance: importance ?? this.importance,
      hitCount: hitCount ?? this.hitCount,
      type: type ?? this.type,
      key: key ?? this.key,
      value: value ?? this.value,
      createdAt: createdAt ?? this.createdAt,
      lastSeenAt: lastSeenAt ?? this.lastSeenAt,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'assistantId': assistantId,
        'content': content,
        'status': status.name,
        'source': source.name,
        'confidence': confidence,
        'importance': importance,
        'hitCount': hitCount,
        'type': type,
        'key': key,
        'value': value,
        'createdAt': createdAt.toIso8601String(),
        'lastSeenAt': lastSeenAt.toIso8601String(),
      };

  static MemoryCandidate fromJson(Map<String, dynamic> json) {
    return MemoryCandidate(
      id: json['id'] as String,
      assistantId: json['assistantId'] as String? ?? '',
      content: json['content'] as String? ?? '',
      status: CandidateStatus.values.firstWhere(
        (e) => e.name == json['status'],
        orElse: () => CandidateStatus.candidate,
      ),
      source: CandidateSource.values.firstWhere(
        (e) => e.name == json['source'],
        orElse: () => CandidateSource.aiInferred,
      ),
      confidence: (json['confidence'] as num?)?.toDouble() ?? 0.60,
      importance: (json['importance'] as num?)?.toDouble() ?? 0.50,
      hitCount: (json['hitCount'] as num?)?.toInt() ?? 1,
      type: json['type'] as String?,
      key: json['key'] as String?,
      value: json['value'] as String?,
      createdAt: DateTime.parse(json['createdAt'] as String),
      lastSeenAt: DateTime.parse(json['lastSeenAt'] as String),
    );
  }
}
