import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:mk_graphql/mk_graphql.dart';

import '../../di/injection.dart';
import '../../graphql/generated/operations.gql.dart';

@RoutePage()
class LanguagesPage extends StatefulWidget {
  const LanguagesPage({super.key});

  @override
  State<LanguagesPage> createState() => _LanguagesPageState();
}

class _LanguagesPageState extends State<LanguagesPage> {
  late Future<GetLanguagesModel> _languagesFuture;
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _loadLanguages();
  }

  void _loadLanguages({FetchPolicy policy = FetchPolicy.cacheFirst}) {
    setState(() {
      _languagesFuture = getIt<GraphQLClient>().getLanguages(
        fetchPolicy: policy,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('World Languages'),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => _loadLanguages(policy: FetchPolicy.networkOnly),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(60),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: TextField(
              decoration: InputDecoration(
                hintText: 'Search languages...',
                prefixIcon: const Icon(Icons.search),
                filled: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(vertical: 0),
              ),
              onChanged: (val) {
                setState(() {
                  _searchQuery = val.trim().toLowerCase();
                });
              },
            ),
          ),
        ),
      ),
      body: FutureBuilder<GetLanguagesModel>(
        future: _languagesFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.error_outline,
                      color: Colors.red,
                      size: 48,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Failed to load languages:\n${snapshot.error}',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: () =>
                          _loadLanguages(policy: FetchPolicy.networkOnly),
                      icon: const Icon(Icons.refresh),
                      label: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            );
          }

          final allLanguages = snapshot.data?.languages ?? [];
          final filteredLanguages = allLanguages.where((l) {
            if (_searchQuery.isEmpty) return true;
            final name = l.name.toLowerCase();
            final native = l.native.toLowerCase();
            final code = l.code.toLowerCase();
            return name.contains(_searchQuery) ||
                native.contains(_searchQuery) ||
                code.contains(_searchQuery);
          }).toList();

          if (filteredLanguages.isEmpty) {
            return const Center(child: Text('No languages found.'));
          }

          return RefreshIndicator(
            onRefresh: () async {
              _loadLanguages(policy: FetchPolicy.networkOnly);
              await _languagesFuture;
            },
            child: ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: filteredLanguages.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final lang = filteredLanguages[index];
                final code = lang.code.toUpperCase();
                final name = lang.name;
                final native = lang.native;
                final isRtl = lang.rtl;

                return Card(
                  elevation: 1,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                    side: BorderSide(
                      color: Theme.of(
                        context,
                      ).colorScheme.outlineVariant.withValues(alpha: 0.4),
                    ),
                  ),
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 4,
                    ),
                    leading: CircleAvatar(
                      backgroundColor: Theme.of(
                        context,
                      ).colorScheme.primaryContainer,
                      child: Text(
                        code,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: Theme.of(
                            context,
                          ).colorScheme.onPrimaryContainer,
                        ),
                      ),
                    ),
                    title: Text(
                      name,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    subtitle: Text('Native: $native'),
                    trailing: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: isRtl
                            ? Colors.amber.withValues(alpha: 0.15)
                            : Colors.blue.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: isRtl ? Colors.amber : Colors.blue,
                        ),
                      ),
                      child: Text(
                        isRtl ? 'RTL' : 'LTR',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: isRtl
                              ? Colors.amberAccent
                              : Colors.lightBlueAccent,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }
}
