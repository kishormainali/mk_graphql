import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:mk_graphql/mk_graphql.dart';

import '../../di/injection.dart';
import '../../graphql/generated/operations.gql.dart';
import '../../router/app_router.gr.dart';

@RoutePage()
class ContinentsPage extends StatefulWidget {
  const ContinentsPage({super.key});

  @override
  State<ContinentsPage> createState() => _ContinentsPageState();
}

class _ContinentsPageState extends State<ContinentsPage> {
  late Future<GetContinentsModel> _continentsFuture;

  @override
  void initState() {
    super.initState();
    _loadContinents();
  }

  void _loadContinents({FetchPolicy policy = FetchPolicy.cacheFirst}) {
    setState(() {
      _continentsFuture = getIt<GraphQLClient>().getContinents(
        fetchPolicy: policy,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('World Continents'),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => _loadContinents(policy: FetchPolicy.networkOnly),
          ),
        ],
      ),
      body: FutureBuilder<GetContinentsModel>(
        future: _continentsFuture,
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
                      'Failed to load continents:\n${snapshot.error}',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: () =>
                          _loadContinents(policy: FetchPolicy.networkOnly),
                      icon: const Icon(Icons.refresh),
                      label: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            );
          }

          final continents = snapshot.data?.continents ?? [];
          if (continents.isEmpty) {
            return const Center(child: Text('No continents found.'));
          }

          return RefreshIndicator(
            onRefresh: () async {
              _loadContinents(policy: FetchPolicy.networkOnly);
              await _continentsFuture;
            },
            child: ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: continents.length,
              separatorBuilder: (_, __) => const SizedBox(height: 16),
              itemBuilder: (context, index) {
                final continent = continents[index];

                return Card(
                  elevation: 2,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                    side: BorderSide(
                      color: Theme.of(
                        context,
                      ).colorScheme.outlineVariant.withValues(alpha: 0.4),
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              continent.name,
                              style: Theme.of(context).textTheme.titleLarge
                                  ?.copyWith(fontWeight: FontWeight.bold),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: Theme.of(
                                  context,
                                ).colorScheme.secondaryContainer,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(
                                '${continent.countries.length} Countries',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSecondaryContainer,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: continent.countries.map((c) {
                            return ActionChip(
                              avatar: Text(c.emoji),
                              label: Text(c.name),
                              visualDensity: VisualDensity.compact,
                              onPressed: () {
                                context.router.push(
                                  CountryDetailsRoute(code: c.code),
                                );
                              },
                            );
                          }).toList(),
                        ),
                      ],
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
