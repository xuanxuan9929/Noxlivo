/// Memory write judge: explicit intent recognition and AI long-term value decision.
///
/// Implements PR 1 of the Memory Lite V2 specification:
/// - Channel A: Rule-based explicit user memory intents (high priority).
/// - Channel B: AI-inferred memory decisions (with confidence & importance separation).
library;

import 'dart:convert';
import 'memory_diagnostic_logger.dart';

enum MemoryDecisionStatus {
  active,
  candidate,
  discard,
}

class MemoryWriteDecision {
  final bool shouldRemember;
  final MemoryDecisionStatus status;
  final bool isExplicit;
  final double confidence;
  final double importance;
  final String memoryContent;
  final String? type; // 'preference' | 'fact' | 'instruction' | 'profile'
  final String? key;
  final String? value;
  final String? reason;

  const MemoryWriteDecision({
    required this.shouldRemember,
    required this.status,
    required this.isExplicit,
    required this.confidence,
    required this.importance,
    required this.memoryContent,
    this.type,
    this.key,
    this.value,
    this.reason,
  });

  Map<String, dynamic> toJson() => {
        'shouldRemember': shouldRemember,
        'status': status.name,
        'isExplicit': isExplicit,
        'confidence': confidence,
        'importance': importance,
        'memoryContent': memoryContent,
        'type': type,
        'key': key,
        'value': value,
        'reason': reason,
      };
}

class MemoryWriteJudge {
  const MemoryWriteJudge._();

  static const double activeConfidenceThreshold = 0.82;
  static const double candidateConfidenceThreshold = 0.55;

  // Patterns for explicit user intents (Channel A)
  static final List<RegExp> _explicitPatterns = <RegExp>[
    RegExp(r'^(?:请|帮我)?(?:记住|牢记|记好|记一下)[:：\s]*(.+)$', caseSensitive: false),
    RegExp(r'^(?:以后|今后|将来)(?:请|都要?|必须|默认)?[:：\s]*(.+)$', caseSensitive: false),
    RegExp(r'^(?:下次|下回)(?:不要?|别|请务必)?[:：\s]*(.+)$', caseSensitive: false),
    RegExp(r'^(?:别再|不要再|千万别)[:：\s]*(.+)$', caseSensitive: false),
    RegExp(r'^(?:默认帮我|默认用|默认选择)[:：\s]*(.+)$', caseSensitive: false),
    RegExp(r'^(?:以后叫我|称呼我为?|叫我)[:：\s]*(.+)$', caseSensitive: false),
    RegExp(r'^(?:我不?喜欢|我讨厌|我超爱|我偏好|我更喜欢)[:：\s]*(.+)$', caseSensitive: false),
    RegExp(r'^(?:我的(?:生日|职业|专业|家乡|爱好|母语|名字)是)[:：\s]*(.+)$', caseSensitive: false),
  ];

  /// Evaluates a user message for explicit intent (Channel A).
  static MemoryWriteDecision? evaluateExplicit(String userMessage) {
    final clean = userMessage.trim();
    if (clean.isEmpty) return null;

    for (final pattern in _explicitPatterns) {
      final match = pattern.firstMatch(clean);
      if (match != null) {
        var content = (match.group(1) ?? clean).trim();
        // If content was stripped to bare words, keep context if needed
        if (content.length < 2) content = clean;

        final decision = MemoryWriteDecision(
          shouldRemember: true,
          status: MemoryDecisionStatus.active,
          isExplicit: true,
          confidence: 0.95,
          importance: 0.85,
          memoryContent: content,
          type: 'preference',
          reason: 'Matched explicit memory pattern: ${pattern.pattern}',
        );

        MemoryDiagnosticLogger.instance.logWrite(
          userMessage: userMessage,
          isExplicit: true,
          confidence: decision.confidence,
          importance: decision.importance,
          status: decision.status.name,
          content: decision.memoryContent,
          reason: decision.reason,
        );

        return decision;
      }
    }
    return null;
  }

  /// Parses structured JSON decision emitted by LLM sidechannel (Channel B).
  static MemoryWriteDecision? parseStructuredDecision(
    String jsonString, {
    required String originalUserMessage,
  }) {
    try {
      final decoded = json.decode(jsonString);
      if (decoded is! Map<String, dynamic>) return null;

      final shouldRemember = decoded['should_remember'] == true;
      if (!shouldRemember) {
        return MemoryWriteDecision(
          shouldRemember: false,
          status: MemoryDecisionStatus.discard,
          isExplicit: false,
          confidence: 0.0,
          importance: 0.0,
          memoryContent: '',
          reason: 'LLM decided should_remember=false',
        );
      }

      final confidence = (decoded['confidence'] as num?)?.toDouble() ?? 0.70;
      final importance = (decoded['importance'] as num?)?.toDouble() ?? 0.60;
      final memoryText = (decoded['memory'] as String?)?.trim() ?? '';
      final type = decoded['type'] as String?;
      final key = decoded['key'] as String?;
      final value = decoded['value'] as String?;

      if (memoryText.isEmpty && (key == null || key.isEmpty)) return null;

      final content = memoryText.isNotEmpty
          ? memoryText
          : '$key: $value';

      final MemoryDecisionStatus status;
      if (confidence >= activeConfidenceThreshold) {
        status = MemoryDecisionStatus.active;
      } else if (confidence >= candidateConfidenceThreshold) {
        status = MemoryDecisionStatus.candidate;
      } else {
        status = MemoryDecisionStatus.discard;
      }

      final decision = MemoryWriteDecision(
        shouldRemember: status != MemoryDecisionStatus.discard,
        status: status,
        isExplicit: false,
        confidence: confidence,
        importance: importance,
        memoryContent: content,
        type: type,
        key: key,
        value: value,
        reason: 'LLM inferred structured memory decision',
      );

      MemoryDiagnosticLogger.instance.logWrite(
        userMessage: originalUserMessage,
        isExplicit: false,
        confidence: decision.confidence,
        importance: decision.importance,
        status: decision.status.name,
        content: decision.memoryContent,
        reason: decision.reason,
      );

      return decision;
    } catch (e) {
      return null;
    }
  }

  /// Combined pipeline: checks explicit rule first, falls back to structured or null.
  static MemoryWriteDecision evaluate({
    required String userMessage,
    String? llmDecisionJson,
  }) {
    // 1. Channel A: explicit intent
    final explicit = evaluateExplicit(userMessage);
    if (explicit != null) return explicit;

    // 2. Channel B: structured LLM decision
    if (llmDecisionJson != null && llmDecisionJson.trim().isNotEmpty) {
      final inferred = parseStructuredDecision(
        llmDecisionJson,
        originalUserMessage: userMessage,
      );
      if (inferred != null) return inferred;
    }

    // 3. Fallback: not a long-term memory candidate
    return const MemoryWriteDecision(
      shouldRemember: false,
      status: MemoryDecisionStatus.discard,
      isExplicit: false,
      confidence: 0.0,
      importance: 0.0,
      memoryContent: '',
      reason: 'No explicit intent and no valid LLM decision',
    );
  }
}
