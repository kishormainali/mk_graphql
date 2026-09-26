import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:mk_graphql/mk_graphql.dart';

import '../../di/injection.dart';
import '../../graphql/generated/anime.gql.dart';
import 'network_activity_monitor.dart';

/// A fixed AniList media id (Cowboy Bebop) used throughout this page so
/// every demo section — stale-while-revalidate, invalidation, retry — is
/// operating on the same cached query and its effects are easy to compare.
const _demoAnimeId = 1;

/// Demonstrates every TanStack-Query-style optimization mk_graphql's
/// GraphQLClient adds on top of a plain request/response GraphQL client:
/// request deduplication, stale-while-revalidate, query invalidation,
/// retry-with-backoff, refetchInterval polling, reconnect/resume refetch
/// triggers, and HiveCache persistence.
@RoutePage()
class OptimizationsPage extends StatefulWidget {
  const OptimizationsPage({super.key});

  @override
  State<OptimizationsPage> createState() => _OptimizationsPageState();
}

class _OptimizationsPageState extends State<OptimizationsPage> {
  final _client = getIt<GraphQLClient>();
  final _monitor = getIt<NetworkActivityMonitor>();

  StreamSubscription<GetAnimeDetailsModel?>? _detailsSub;
  StreamSubscription<GetGenresModel?>? _genresSub;

  GetAnimeDetailsModel? _details;
  DateTime? _detailsWrittenAt;
  GetGenresModel? _genres;
  DateTime? _genresWrittenAt;

  String? _dedupResult;
  String? _retryResult;
  String? _invalidateResult;
  String? _pauseResult;
  bool _isPaused = false;
  bool _busy = false;

  final _detailsReq = const GetAnimeDetailsReq(
    variables: GetAnimeDetailsVars(id: _demoAnimeId),
  );

  @override
  void initState() {
    super.initState();
    _monitor.addListener(_onActivity);

    // Live-watch the details query so stale-while-revalidate, invalidation,
    // and the reconnect/resume triggers all have a visible subscriber to
    // act on — none of those background refetches happen for a query
    // nobody's watching.
    _detailsSub = _client.watchQuery(_detailsReq).listen((data) {
      setState(() {
        _details = data;
        _detailsWrittenAt = _client.cache.writtenAt(_detailsReq);
      });
    });

    // Polled every 8s via refetchInterval while this page is open — proves
    // the client, not this widget, is driving the refetch.
    final genresReq = const GetGenresReq(
      variables: GetGenresVars(),
      refetchInterval: Duration(seconds: 8),
    );
    _genresSub = _client.watchQuery(genresReq).listen((data) {
      setState(() {
        _genres = data;
        _genresWrittenAt = _client.cache.writtenAt(genresReq);
      });
    });
  }

  @override
  void dispose() {
    // The demo toggle above calls notifyAppPaused() on the app-wide shared
    // client (not a page-local one) — leaving this page paused would
    // silently stop background refetches everywhere else in the app until
    // it's genuinely backgrounded/foregrounded for real. Clear it here so
    // this demo page can't leave that behind.
    if (_isPaused) _client.notifyAppResumed();
    _monitor.removeListener(_onActivity);
    _detailsSub?.cancel();
    _genresSub?.cancel();
    super.dispose();
  }

  void _onActivity() {
    if (mounted) setState(() {});
  }

  Future<void> _runDedupDemo() async {
    setState(() {
      _busy = true;
      _dedupResult = null;
    });
    final before = _monitor.totalSent;
    try {
      await Future.wait(List.generate(
        5,
        (_) => _client.future(const GetGenresReq(
          variables: GetGenresVars(),
          fetchPolicy: FetchPolicy.networkOnly,
        )),
      ));
      final sent = _monitor.totalSent - before;
      setState(() {
        _dedupResult = '5 identical calls fired concurrently → '
            '$sent network request${sent == 1 ? '' : 's'} actually sent.';
      });
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _runRetryDemo() async {
    setState(() {
      _busy = true;
      _retryResult = null;
    });
    _monitor.simulateFailures('GetAnimeDetails', 2);
    // A raw list-length cutoff, not totalSent (a count of "sent"-only
    // entries) — the log interleaves "sent"/"succeeded"/"failed" entries,
    // so skipping by totalSent would skip the wrong number of raw entries.
    final startIndex = _monitor.log.length;
    try {
      await _client.refetchGetAnimeDetails(id: _demoAnimeId);
      final attempts = _monitor.log
          .skip(startIndex)
          .where((e) =>
              e.operationName == 'GetAnimeDetails' && e.event == 'sent')
          .length;
      setState(() {
        _retryResult = 'Succeeded after $attempts attempt'
            '${attempts == 1 ? '' : 's'} (first 2 were simulated failures, '
            'recovered automatically by RetryOptions).';
      });
    } catch (e) {
      setState(() => _retryResult = 'Gave up: $e');
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _runInvalidateDemo() async {
    setState(() {
      _busy = true;
      _invalidateResult = null;
    });
    try {
      await _client.invalidateQueries(types: const ['Media']);
      setState(() {
        _invalidateResult = 'invalidateQueries(types: ["Media"]) ran — the '
            'watched details query above was evicted and background-'
            'refetched in place. (Matching by __typename, not just by '
            'operation name — every cached query whose result touched a '
            'Media entity, not only this one.)';
      });
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _runPauseDemo() async {
    setState(() {
      _busy = true;
      _pauseResult = null;
    });
    try {
      if (!_isPaused) {
        _client.notifyAppPaused();
        final before = _monitor.totalSent;
        // Proves it, rather than just claiming it: notifyReconnected would
        // normally refetch the actively-watched queries above.
        await _client.notifyReconnected();
        final sent = _monitor.totalSent - before;
        setState(() {
          _isPaused = true;
          _pauseResult = 'Paused — notifyReconnected() right after fired '
              '$sent network request${sent == 1 ? '' : 's'} for the '
              'actively-watched queries above (should be 0).';
        });
      } else {
        final before = _monitor.totalSent;
        await _client.notifyAppResumed();
        final sent = _monitor.totalSent - before;
        setState(() {
          _isPaused = false;
          _pauseResult = 'Resumed — notifyAppResumed() immediately '
              'refetched $sent quer${sent == 1 ? 'y' : 'ies'} to catch up.';
        });
      }
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _clearPersistedCache() async {
    _client.cache.clear();
    setState(() {
      _invalidateResult = 'Cache cleared. Persisted data on disk (HiveCache) '
          'is gone too — reopening this page will hit the network fresh.';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B0F19),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0B0F19),
        elevation: 0,
        title: const Text('Client Optimizations'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _Section(
            title: 'Request deduplication',
            description: 'Concurrent identical queries share a single '
                'in-flight network call instead of each firing separately.',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ElevatedButton(
                  onPressed: _busy ? null : _runDedupDemo,
                  child: const Text('Fire 5 concurrent GetGenres requests'),
                ),
                if (_dedupResult != null) ...[
                  const SizedBox(height: 8),
                  Text(_dedupResult!, style: _resultStyle),
                ],
              ],
            ),
          ),
          _Section(
            title: 'Stale-while-revalidate',
            description: 'This details query (defaultStaleTime: 30s) is '
                'live-watched below. Cached reads still return instantly, '
                'but once the entry is older than 30s the client kicks off '
                'a background refetch on its own — watch "writtenAt" update '
                'without you pressing anything.',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _details?.media?.title?.romaji ?? 'Loading…',
                  style: const TextStyle(
                      color: Colors.white, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                Text(
                  _detailsWrittenAt == null
                      ? 'writtenAt: never'
                      : 'writtenAt: ${_detailsWrittenAt!.toIso8601String()} '
                          '(${_ago(_detailsWrittenAt!)})',
                  style: _resultStyle,
                ),
              ],
            ),
          ),
          _Section(
            title: 'refetchInterval polling',
            description: 'GetGenres is watched with refetchInterval: 8s — '
                'the client polls it in the background for as long as this '
                'page (the subscriber) stays open.',
            child: Text(
              _genresWrittenAt == null
                  ? 'Loading…'
                  : '${_genres?.genreCollection?.length ?? 0} genres · last '
                      'refreshed ${_ago(_genresWrittenAt!)}',
              style: _resultStyle,
            ),
          ),
          _Section(
            title: 'Query invalidation',
            description: 'invalidateQueries(types: ["Media"]) evicts every '
                'cached query whose result touched a Media entity and '
                'background-refetches any of them with an active watcher — '
                'like the details query above. (invalidateQueries also '
                'supports matching by operation name via `operationNames:`, '
                'when you want to target one specific query instead of '
                'every query touching a type.)',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ElevatedButton(
                  onPressed: _busy ? null : _runInvalidateDemo,
                  child: const Text('Invalidate all "Media" queries'),
                ),
                if (_invalidateResult != null) ...[
                  const SizedBox(height: 8),
                  Text(_invalidateResult!, style: _resultStyle),
                ],
              ],
            ),
          ),
          _Section(
            title: 'Retry with backoff',
            description: 'The client retries transient failures '
                'automatically (defaultRetry: RetryOptions(), 3 attempts). '
                'This simulates 2 failed attempts before letting the 3rd '
                'through, so you can watch it recover.',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ElevatedButton(
                  onPressed: _busy ? null : _runRetryDemo,
                  child: const Text('Simulate 2 flaky attempts, then fetch'),
                ),
                if (_retryResult != null) ...[
                  const SizedBox(height: 8),
                  Text(_retryResult!, style: _resultStyle),
                ],
              ],
            ),
          ),
          _Section(
            title: 'Reconnect / app-resume refetch',
            description: 'Call these from a connectivity listener or '
                'AppLifecycleState.resumed in a real app — every actively '
                'watched query (both above) refetches in the background.',
            child: Wrap(
              spacing: 8,
              children: [
                OutlinedButton(
                  onPressed: _busy
                      ? null
                      : () async {
                          final messenger = ScaffoldMessenger.of(context);
                          await _client.notifyReconnected();
                          if (!mounted) return;
                          messenger.showSnackBar(
                            const SnackBar(
                                content: Text('notifyReconnected() fired')),
                          );
                        },
                  child: const Text('notifyReconnected()'),
                ),
                OutlinedButton(
                  onPressed: _busy
                      ? null
                      : () async {
                          final messenger = ScaffoldMessenger.of(context);
                          await _client.notifyAppResumed();
                          if (!mounted) return;
                          messenger.showSnackBar(
                            const SnackBar(
                                content: Text('notifyAppResumed() fired')),
                          );
                        },
                  child: const Text('notifyAppResumed()'),
                ),
              ],
            ),
          ),
          _Section(
            title: 'Battery saver: notifyAppPaused',
            description: 'The real app wires this to '
                'WidgetsBindingObserver (see main.dart) so it fires for '
                'real when the app backgrounds — this button just lets you '
                'trigger the same thing here. While paused, every '
                'opportunistic background refetch above (staleness, '
                'refetchInterval, invalidateQueries, notifyReconnected) is '
                'skipped instead of waking the radio for a screen nobody '
                'can see.',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                OutlinedButton(
                  onPressed: _busy ? null : _runPauseDemo,
                  child: Text(_isPaused
                      ? 'Resume (notifyAppResumed)'
                      : 'Pause (notifyAppPaused), then try notifyReconnected'),
                ),
                if (_pauseResult != null) ...[
                  const SizedBox(height: 8),
                  Text(_pauseResult!, style: _resultStyle),
                ],
              ],
            ),
          ),
          _Section(
            title: 'Persistent cache (HiveCache)',
            description: 'Every query on this page is written through to a '
                'Hive box on disk. Fully close and reopen the app — the '
                'data above still appears instantly from disk before any '
                'network call completes.',
            child: OutlinedButton(
              onPressed: _busy ? null : _clearPersistedCache,
              child: const Text('Clear persisted cache'),
            ),
          ),
          _Section(
            title: 'Live network activity (ground truth)',
            description: 'Every line here is an actual HTTP call that left '
                'the device — this is what proves dedup/retry above, not '
                'just what the UI claims.',
            child: _monitor.log.isEmpty
                ? const Text('No network activity yet.', style: _resultStyle)
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: _monitor.log.reversed.take(12).map((e) {
                      return Text(
                        '${e.time.toIso8601String().substring(11, 19)}  '
                        '${e.operationName.padRight(16)} ${e.event}',
                        style: _resultStyle.copyWith(
                          fontFamily: 'monospace',
                          color: e.event.startsWith('failed')
                              ? Colors.redAccent
                              : Colors.grey.shade400,
                        ),
                      );
                    }).toList(),
                  ),
          ),
        ],
      ),
    );
  }
}

const _resultStyle = TextStyle(color: Colors.grey, fontSize: 12);

/// Human-readable age, capped at "over a day ago" — a HiveCache-hydrated
/// entry is deliberately timestamped at epoch 0 (see [InMemoryCache.seed]),
/// so a raw seconds count would read as a multi-decade number on first
/// paint after a restart.
String _ago(DateTime time) {
  final diff = DateTime.now().difference(time);
  if (diff.inDays >= 1) return 'over a day ago';
  if (diff.inMinutes >= 1) return '${diff.inMinutes}m ago';
  return '${diff.inSeconds}s ago';
}

class _Section extends StatelessWidget {
  final String title;
  final String description;
  final Widget child;

  const _Section({
    required this.title,
    required this.description,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 4),
            Text(description, style: _resultStyle),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}
