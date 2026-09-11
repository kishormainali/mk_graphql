import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:mk_graphql/mk_graphql.dart';

import '../../di/injection.dart';
import '../../graphql/generated/operations.gql.dart';

@RoutePage()
class CountryDetailsPage extends StatefulWidget {
  final String code;

  const CountryDetailsPage({super.key, required this.code});

  @override
  State<CountryDetailsPage> createState() => _CountryDetailsPageState();
}

class _CountryDetailsPageState extends State<CountryDetailsPage> {
  late Future<GetCountryDetailsModel> _detailsFuture;

  @override
  void initState() {
    super.initState();
    _loadDetails();
  }

  void _loadDetails({FetchPolicy policy = FetchPolicy.cacheFirst}) {
    setState(() {
      _detailsFuture = getIt<GraphQLClient>().getCountryDetails(
        code: widget.code,
        fetchPolicy: policy,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Country Details'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => _loadDetails(policy: FetchPolicy.networkOnly),
          ),
        ],
      ),
      body: FutureBuilder<GetCountryDetailsModel>(
        future: _detailsFuture,
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
                      'Failed to load details:\n${snapshot.error}',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: () =>
                          _loadDetails(policy: FetchPolicy.networkOnly),
                      icon: const Icon(Icons.refresh),
                      label: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            );
          }

          final country = snapshot.data?.country;
          if (country == null) {
            return const Center(child: Text('Country details not found.'));
          }

          final emoji = country.emoji;
          final name = country.name;
          final native = country.native;
          final code = country.code;
          final continentName = country.continent.name;
          final continentCode = country.continent.code;
          final languages = country.languages;
          final states = country.states;

          return SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Flag header card
                Container(
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        Theme.of(context).colorScheme.primaryContainer,
                        Theme.of(context).colorScheme.surfaceContainerHigh,
                      ],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: Column(
                    children: [
                      Text(emoji, style: const TextStyle(fontSize: 72)),
                      const SizedBox(height: 12),
                      Text(
                        name,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '$native • $code',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),

                // Core details card
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'General Information',
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.bold),
                        ),
                        const Divider(height: 20),
                        _buildInfoRow(
                          context,
                          icon: Icons.public,
                          label: 'Continent',
                          value: '$continentName ($continentCode)',
                        ),
                        if (country.capital != null &&
                            country.capital!.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          _buildInfoRow(
                            context,
                            icon: Icons.location_city,
                            label: 'Capital City',
                            value: country.capital!,
                          ),
                        ],
                        if (country.phone.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          _buildInfoRow(
                            context,
                            icon: Icons.phone,
                            label: 'Calling Code',
                            value: '+${country.phone}',
                          ),
                        ],
                        if (country.currency != null &&
                            country.currency!.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          _buildInfoRow(
                            context,
                            icon: Icons.monetization_on_outlined,
                            label: 'Currency',
                            value: country.currency!,
                          ),
                        ],
                        if (country.awsRegion.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          _buildInfoRow(
                            context,
                            icon: Icons.cloud_queue,
                            label: 'AWS Cloud Region',
                            value: country.awsRegion,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // Spoken Languages
                if (languages.isNotEmpty) ...[
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(
                                Icons.translate,
                                size: 20,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                'Languages (${languages.length})',
                                style: Theme.of(context).textTheme.titleMedium
                                    ?.copyWith(fontWeight: FontWeight.bold),
                              ),
                            ],
                          ),
                          const Divider(height: 20),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: languages.map((lang) {
                              final lName = lang.name;
                              final lNative = lang.native;
                              final isRtl = lang.rtl;
                              return Chip(
                                avatar: const Icon(Icons.language, size: 16),
                                label: Text(
                                  '$lName ($lNative)${isRtl ? " [RTL]" : ""}',
                                ),
                              );
                            }).toList(),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                ],

                // States / Regions
                if (states.isNotEmpty)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(
                                Icons.map_outlined,
                                size: 20,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                'States / Provinces (${states.length})',
                                style: Theme.of(context).textTheme.titleMedium
                                    ?.copyWith(fontWeight: FontWeight.bold),
                              ),
                            ],
                          ),
                          const Divider(height: 20),
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: states.take(40).map((s) {
                              return Chip(
                                label: Text(s.name),
                                visualDensity: VisualDensity.compact,
                              );
                            }).toList(),
                          ),
                          if (states.length > 40) ...[
                            const SizedBox(height: 8),
                            Text(
                              '+ ${states.length - 40} more states',
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(color: Colors.grey),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildInfoRow(
    BuildContext context, {
    required IconData icon,
    required String label,
    required String value,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 20, color: Theme.of(context).colorScheme.primary),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: Theme.of(context).colorScheme.outline,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                value,
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
