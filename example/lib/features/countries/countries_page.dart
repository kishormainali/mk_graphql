import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:mk_graphql/mk_graphql.dart';

import '../../di/injection.dart';
import '../../graphql/generated/operations.gql.dart';
import '../../router/app_router.gr.dart';

@RoutePage()
class CountriesPage extends StatefulWidget {
  const CountriesPage({super.key});

  @override
  State<CountriesPage> createState() => _CountriesPageState();
}

class _CountriesPageState extends State<CountriesPage> {
  late Future<GetCountriesModel> _countriesFuture;
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _loadCountries();
  }

  void _loadCountries({FetchPolicy policy = FetchPolicy.cacheFirst}) {
    setState(() {
      _countriesFuture = getIt<GraphQLClient>().getCountries(
        fetchPolicy: policy,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('World Countries'),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => _loadCountries(policy: FetchPolicy.networkOnly),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(60),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: TextField(
              decoration: InputDecoration(
                hintText: 'Search countries or code...',
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
      body: FutureBuilder<GetCountriesModel>(
        future: _countriesFuture,
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
                      'Failed to load countries:\n${snapshot.error}',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: () =>
                          _loadCountries(policy: FetchPolicy.networkOnly),
                      icon: const Icon(Icons.refresh),
                      label: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            );
          }

          final allCountries = snapshot.data?.countries ?? [];
          final filteredCountries = allCountries.where((c) {
            if (_searchQuery.isEmpty) return true;
            final name = c.name.toLowerCase();
            final code = c.code.toLowerCase();
            final capital = c.capital?.toLowerCase() ?? '';
            return name.contains(_searchQuery) ||
                code.contains(_searchQuery) ||
                capital.contains(_searchQuery);
          }).toList();

          if (filteredCountries.isEmpty) {
            return const Center(child: Text('No countries match your search.'));
          }

          return RefreshIndicator(
            onRefresh: () async {
              _loadCountries(policy: FetchPolicy.networkOnly);
              await _countriesFuture;
            },
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              itemCount: filteredCountries.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final country = filteredCountries[index];
                final emoji = country.emoji;
                final name = country.name;
                final code = country.code;
                final continentName = country.continent.name;

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
                      vertical: 6,
                    ),
                    leading: Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: Theme.of(
                          context,
                        ).colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      alignment: Alignment.center,
                      child: Text(emoji, style: const TextStyle(fontSize: 26)),
                    ),
                    title: Row(
                      children: [
                        Expanded(
                          child: Text(
                            name,
                            style: const TextStyle(fontWeight: FontWeight.bold),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: Theme.of(
                              context,
                            ).colorScheme.primaryContainer,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            code,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              color: Theme.of(
                                context,
                              ).colorScheme.onPrimaryContainer,
                            ),
                          ),
                        ),
                      ],
                    ),
                    subtitle: Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Row(
                        children: [
                          if (country.capital != null &&
                              country.capital!.isNotEmpty) ...[
                            const Icon(
                              Icons.location_city,
                              size: 14,
                              color: Colors.grey,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              country.capital!,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                            const SizedBox(width: 12),
                          ],
                          const Icon(
                            Icons.public,
                            size: 14,
                            color: Colors.grey,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            continentName,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () {
                      context.router.push(
                        CountryDetailsRoute(code: country.code),
                      );
                    },
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
