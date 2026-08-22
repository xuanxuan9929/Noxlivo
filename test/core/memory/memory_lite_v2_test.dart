import 'package:flutter_test/flutter_test.dart';
import 'package:cuplivo/core/memory/memory_diagnostic_logger.dart';
import 'package:cuplivo/core/memory/memory_write_judge.dart';
import 'package:cuplivo/core/memory/memory_candidate.dart';
import 'package:cuplivo/core/memory/memory_merge_detector.dart';
import 'package:cuplivo/core/memory/memory_recall_ranker.dart';
import 'package:cuplivo/core/memory/three_layer_memory_policy.dart';
import 'package:cuplivo/core/models/assistant_memory.dart';

void main() {
  group('MemoryDiagnosticLogger', () {
    setUp(() {
      MemoryDiagnosticLogger.instance.clear();
    });

    test('logs write and recall diagnostics correctly', () {
      MemoryDiagnosticLogger.instance.logWrite(
        userMessage: '记住我喜欢吃苹果',
        isExplicit: true,
        confidence: 0.95,
        importance: 0.85,
        status: 'active',
        content: '我喜欢吃苹果',
      );

      final logs = MemoryDiagnosticLogger.instance.getRecentLogs();
      expect(logs.length, 1);
      expect(logs.first.category, 'write');
      expect(logs.first.details['confidence'], 0.95);
    });
  });

  group('MemoryWriteJudge', () {
    test('matches explicit user memory intents (Channel A)', () {
      final d1 = MemoryWriteJudge.evaluateExplicit('请记住我喜欢喝美式咖啡');
      expect(d1, isNotNull);
      expect(d1!.shouldRemember, isTrue);
      expect(d1.status, MemoryDecisionStatus.active);
      expect(d1.isExplicit, isTrue);
      expect(d1.memoryContent, contains('我喜欢喝美式咖啡'));

      final d2 = MemoryWriteJudge.evaluateExplicit('以后请默认用中文回答');
      expect(d2, isNotNull);
      expect(d2!.status, MemoryDecisionStatus.active);

      final d3 = MemoryWriteJudge.evaluateExplicit('今天天气真不错');
      expect(d3, isNull);
    });

    test('parses structured LLM decisions (Channel B)', () {
      const jsonStr = '''
      {
        "should_remember": true,
        "confidence": 0.88,
        "importance": 0.75,
        "type": "preference",
        "key": "favorite_food",
        "value": "ramen",
        "memory": "用户最喜欢的食物是拉面"
      }
      ''';

      final d = MemoryWriteJudge.parseStructuredDecision(
        jsonStr,
        originalUserMessage: '我最爱吃拉面了',
      );
      expect(d, isNotNull);
      expect(d!.shouldRemember, isTrue);
      expect(d.status, MemoryDecisionStatus.active);
      expect(d.confidence, 0.88);
      expect(d.key, 'favorite_food');
    });

    test('classifies confidence between 0.55 and 0.82 as candidate', () {
      const jsonStr = '''
      {
        "should_remember": true,
        "confidence": 0.65,
        "importance": 0.50,
        "memory": "用户今天可能有点累"
      }
      ''';

      final d = MemoryWriteJudge.parseStructuredDecision(
        jsonStr,
        originalUserMessage: '今天有点累',
      );
      expect(d, isNotNull);
      expect(d!.status, MemoryDecisionStatus.candidate);
    });
  });

  group('MemoryCandidate State Machine', () {
    test('promotes to active when confidence reaches 0.82', () {
      final now = DateTime.now();
      var candidate = MemoryCandidate(
        id: 'c1',
        assistantId: 'a1',
        content: '用户对 Flutter 感兴趣',
        status: CandidateStatus.candidate,
        confidence: 0.60,
        createdAt: now,
        lastSeenAt: now,
      );

      expect(candidate.status, CandidateStatus.candidate);

      // Hit 1: 0.60 + 0.15 = 0.75 -> still candidate
      candidate = candidate.recordHit();
      expect(candidate.confidence, closeTo(0.75, 0.01));
      expect(candidate.status, CandidateStatus.candidate);

      // Hit 2: 0.75 + 0.15 = 0.90 >= 0.82 -> promoted to active
      candidate = candidate.recordHit();
      expect(candidate.confidence, closeTo(0.90, 0.01));
      expect(candidate.status, CandidateStatus.active);
    });
  });

  group('MemoryMergeDetector', () {
    test('merges high similarity duplicates', () {
      final now = DateTime.now();
      final pool = [
        MemoryCandidate(
          id: '1',
          assistantId: 'a1',
          content: '用户喜欢吃苹果',
          status: CandidateStatus.active,
          createdAt: now,
          lastSeenAt: now,
        ),
      ];

      final incoming = MemoryCandidate(
        id: '2',
        assistantId: 'a1',
        content: '用户非常喜欢吃苹果',
        status: CandidateStatus.active,
        createdAt: now,
        lastSeenAt: now,
      );

      final result = MemoryMergeDetector.process(
        incoming: incoming,
        existingPool: pool,
      );

      expect(result.action, MergeAction.mergedDuplicate);
      expect(result.resultCandidate.hitCount, 2);
    });

    test('supersedes old memory on structured key conflict', () {
      final now = DateTime.now();
      final pool = [
        MemoryCandidate(
          id: '1',
          assistantId: 'a1',
          content: 'favorite_color: blue',
          key: 'favorite_color',
          value: 'blue',
          status: CandidateStatus.active,
          createdAt: now,
          lastSeenAt: now,
        ),
      ];

      final incoming = MemoryCandidate(
        id: '2',
        assistantId: 'a1',
        content: 'favorite_color: green',
        key: 'favorite_color',
        value: 'green',
        status: CandidateStatus.active,
        createdAt: now,
        lastSeenAt: now,
      );

      final result = MemoryMergeDetector.process(
        incoming: incoming,
        existingPool: pool,
      );

      expect(result.action, MergeAction.supersededOldKey);
      expect(result.supersededCandidate?.status, CandidateStatus.superseded);
      expect(result.resultCandidate.status, CandidateStatus.active);
      expect(result.resultCandidate.value, 'green');
    });
  });

  group('MemoryRecallRanker & ThreeLayerMemoryPolicy', () {
    test('ranks relevant memories and rejects unrelated ones', () {
      final now = DateTime.now();
      final candidates = [
        MemoryCandidate(
          id: '1',
          assistantId: 'a1',
          content: '用户家在天津',
          type: 'fact',
          importance: 0.9,
          status: CandidateStatus.active,
          createdAt: now,
          lastSeenAt: now,
        ),
        MemoryCandidate(
          id: '2',
          assistantId: 'a1',
          content: '用户喜欢喝黑咖啡',
          type: 'preference',
          importance: 0.8,
          status: CandidateStatus.active,
          createdAt: now,
          lastSeenAt: now,
        ),
      ];

      // Query about coffee
      final selected = MemoryRecallRanker.rankAndFilter(
        candidates: candidates,
        query: '帮我推荐个咖啡豆',
        maxCount: 2,
      );

      expect(selected.length, 1);
      expect(selected.first.id, '2');
      expect(selected.first.content, contains('咖啡'));

      // Query completely unrelated
      final unrelated = MemoryRecallRanker.rankAndFilter(
        candidates: candidates,
        query: '量子力学与相对论的统一性原理',
        maxCount: 2,
        minThreshold: 0.30,
      );
      expect(unrelated.isEmpty, isTrue);
    });

    test('ThreeLayerMemoryPolicy.selectLongTermMemories integrates multi-turn context', () {
      final memories = [
        const AssistantMemory(id: 1, assistantId: 'a1', content: '用户在北京工作'),
        const AssistantMemory(id: 2, assistantId: 'a1', content: '用户喜欢吃辣'),
      ];

      final res = ThreeLayerMemoryPolicy.selectLongTermMemories(
        memories: memories,
        query: '有什么好吃的川菜推荐吗',
        recentHistory: ['今天想吃点重口味的'],
        limit: 2,
        maxChars: 1000,
      );

      expect(res.length, 1);
      expect(res.first.id, 2);
    });
  });
}
