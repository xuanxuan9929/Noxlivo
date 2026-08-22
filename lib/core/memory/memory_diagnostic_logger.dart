/// Diagnostic and audit logging for the Cuplivo Memory Lite subsystem.
///
/// Implements PR 0 of the Memory Lite V2 specification:
/// Records why a memory was written, why it was promoted/discarded,
/// how each recall candidate was scored, and what was finally injected.
library;

import 'dart:collection';

class MemoryDiagnosticEntry {
  final DateTime timestamp;
  final String category; // 'write' | 'candidate' | 'recall' | 'conflict'
  final String message;
  final Map<String, dynamic> details;

  MemoryDiagnosticEntry({
    required this.category,
    required this.message,
    Map<String, dynamic>? details,
    DateTime? timestamp,
  })  : timestamp = timestamp ?? DateTime.now(),
        details = details ?? const <String, dynamic>{};

  @override
  String toString() {
    final timeStr = timestamp.toIso8601String().substring(11, 19);
    final detailStr = details.isNotEmpty ? ' | details: $details' : '';
    return '[$timeStr][Memory ${category.toUpperCase()}] $message$detailStr';
  }
}

class MemoryDiagnosticLogger {
  MemoryDiagnosticLogger._();
  static final MemoryDiagnosticLogger instance = MemoryDiagnosticLogger._();

  bool enabled = true;
  static const int _maxLogs = 200;
  final DoubleLinkedQueue<MemoryDiagnosticEntry> _logs =
      DoubleLinkedQueue<MemoryDiagnosticEntry>();

  void logWrite({
    required String userMessage,
    required bool isExplicit,
    required double confidence,
    required double importance,
    required String status,
    String? content,
    String? reason,
  }) {
    if (!enabled) return;
    _add(
      MemoryDiagnosticEntry(
        category: 'write',
        message: 'Write evaluated: status=$status, conf=${confidence.toStringAsFixed(2)}, imp=${importance.toStringAsFixed(2)}',
        details: {
          'userMessage': userMessage,
          'isExplicit': isExplicit,
          'confidence': confidence,
          'importance': importance,
          'status': status,
          'content': content,
          'reason': reason,
        },
      ),
    );
  }

  void logCandidate({
    required String candidateId,
    required String action, // 'created' | 'hit_boost' | 'promoted' | 'discarded'
    required int hitCount,
    required double confidence,
    String? content,
  }) {
    if (!enabled) return;
    _add(
      MemoryDiagnosticEntry(
        category: 'candidate',
        message: 'Candidate $action [id=$candidateId]: count=$hitCount, conf=${confidence.toStringAsFixed(2)}',
        details: {
          'candidateId': candidateId,
          'action': action,
          'hitCount': hitCount,
          'confidence': confidence,
          'content': content,
        },
      ),
    );
  }

  void logConflict({
    required String action, // 'merged_duplicate' | 'superseded_old_key' | 'kept_separate'
    required String newContent,
    String? oldContent,
    String? reason,
  }) {
    if (!enabled) return;
    _add(
      MemoryDiagnosticEntry(
        category: 'conflict',
        message: 'Conflict check: action=$action ($reason)',
        details: {
          'action': action,
          'newContent': newContent,
          'oldContent': oldContent,
          'reason': reason,
        },
      ),
    );
  }

  void logRecall({
    required String query,
    required int candidatePoolSize,
    required int selectedCount,
    required int injectedChars,
    required List<Map<String, dynamic>> scoredItems,
  }) {
    if (!enabled) return;
    _add(
      MemoryDiagnosticEntry(
        category: 'recall',
        message: 'Recall query="$query": candidates=$candidatePoolSize, selected=$selectedCount, chars=$injectedChars',
        details: {
          'query': query,
          'poolSize': candidatePoolSize,
          'selectedCount': selectedCount,
          'injectedChars': injectedChars,
          'scoredItems': scoredItems,
        },
      ),
    );
  }

  void _add(MemoryDiagnosticEntry entry) {
    _logs.addLast(entry);
    while (_logs.length > _maxLogs) {
      _logs.removeFirst();
    }
  }

  List<MemoryDiagnosticEntry> getRecentLogs({int limit = 50}) {
    final list = _logs.toList();
    if (list.length <= limit) return list;
    return list.sublist(list.length - limit);
  }

  void clear() {
    _logs.clear();
  }
}
