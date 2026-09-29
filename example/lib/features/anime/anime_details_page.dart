import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../di/injection.dart';
import '../../graphql/generated/anime.gql.dart';
import 'bloc/anime_details_cubit.dart';

@RoutePage()
class AnimeDetailsPage extends StatelessWidget {
  final int id;
  const AnimeDetailsPage({super.key, @pathParam required this.id});

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => getIt<AnimeDetailsCubit>()..load(id),
      child: _AnimeDetailsView(id: id),
    );
  }
}

class _AnimeDetailsView extends StatelessWidget {
  final int id;
  const _AnimeDetailsView({required this.id});

  String _cleanHtml(String? text) {
    if (text == null) return 'No description available.';
    return text
        .replaceAll(RegExp(r'<br\s*/?>'), '\n')
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .trim();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B0F19),
      body: BlocBuilder<AnimeDetailsCubit, AnimeDetailsState>(
        builder: (context, state) {
          return state.when(
            initial: () => const Center(
              child: CircularProgressIndicator(color: Color(0xFF38BDF8)),
            ),
            loading: () => const Center(
              child: CircularProgressIndicator(color: Color(0xFF38BDF8)),
            ),
            failure: (error) => Center(
              child: Padding(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.error_outline,
                      color: Colors.redAccent,
                      size: 56,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Failed to load anime details:\n$error',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white70),
                    ),
                    const SizedBox(height: 16),
                    ElevatedButton.icon(
                      onPressed: () =>
                          context.read<AnimeDetailsCubit>().load(id),
                      icon: const Icon(Icons.refresh),
                      label: const Text('Try Again'),
                    ),
                  ],
                ),
              ),
            ),
            success: (media) {
              final bannerUrl = media.bannerImage;
              final coverUrl =
                  media.coverImage?.extraLarge ?? media.coverImage?.large;
              final titleEnglish = media.title?.english;
              final titleRomaji = media.title?.romaji ?? 'Unknown Title';
              final titleNative = media.title?.native;
              final description = _cleanHtml(media.description);
              final genres = media.genres?.whereType<String>().toList() ?? [];

              return RefreshIndicator(
                color: const Color(0xFF38BDF8),
                backgroundColor: const Color(0xFF1E293B),
                onRefresh: () =>
                    context.read<AnimeDetailsCubit>().refetch(id),
                child: CustomScrollView(
                  slivers: [
                    // Collapsible App Bar with Banner
                    SliverAppBar(
                      expandedHeight: 240,
                      pinned: true,
                      backgroundColor: const Color(0xFF0B0F19),
                      flexibleSpace: FlexibleSpaceBar(
                        background: Stack(
                          fit: StackFit.expand,
                          children: [
                            if (bannerUrl != null)
                              Image.network(
                                bannerUrl,
                                fit: BoxFit.cover,
                                errorBuilder: (context, error, stackTrace) =>
                                    Container(
                                  color: const Color(0xFF1E293B),
                                ),
                              )
                            else if (coverUrl != null)
                              Image.network(
                                coverUrl,
                                fit: BoxFit.cover,
                              ),
                            // Gradient overlays
                            Positioned.fill(
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.topCenter,
                                    end: Alignment.bottomCenter,
                                    colors: [
                                      Colors.black.withValues(alpha: 0.3),
                                      const Color(0xFF0B0F19)
                                          .withValues(alpha: 0.9),
                                      const Color(0xFF0B0F19),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),

                    // Main Details Content
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16.0, vertical: 12.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Poster & Title Info Row
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                // Poster Card
                                if (coverUrl != null)
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(12),
                                    child: Container(
                                      width: 110,
                                      height: 160,
                                      decoration: BoxDecoration(
                                        boxShadow: [
                                          BoxShadow(
                                            color: Colors.black
                                                .withValues(alpha: 0.5),
                                            blurRadius: 10,
                                            offset: const Offset(0, 4),
                                          ),
                                        ],
                                      ),
                                      child: Image.network(
                                        coverUrl,
                                        fit: BoxFit.cover,
                                      ),
                                    ),
                                  ),
                                const SizedBox(width: 16),

                                // Titles & Meta Badges
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      if (titleEnglish != null &&
                                          titleEnglish.isNotEmpty)
                                        Text(
                                          titleEnglish,
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 18,
                                            fontWeight: FontWeight.bold,
                                            height: 1.2,
                                          ),
                                        ),
                                      Text(
                                        titleRomaji,
                                        style: TextStyle(
                                          color: Colors.grey.shade400,
                                          fontSize: 14,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                      if (titleNative != null &&
                                          titleNative.isNotEmpty)
                                        Padding(
                                          padding:
                                              const EdgeInsets.only(top: 2.0),
                                          child: Text(
                                            titleNative,
                                            style: TextStyle(
                                              color: Colors.grey.shade600,
                                              fontSize: 12,
                                            ),
                                          ),
                                        ),
                                      const SizedBox(height: 12),

                                      // Badges (Format, Status, Year)
                                      Wrap(
                                        spacing: 6,
                                        runSpacing: 6,
                                        children: [
                                          if (media.status != null)
                                            _Badge(
                                              icon: Icons.info_outline,
                                              color: media.status ==
                                                      MediaStatus.finished
                                                  ? const Color(0xFF10B981)
                                                  : Colors.amber,
                                              text: media.status!.name
                                                  .toUpperCase(),
                                            ),
                                          if (media.seasonYear != null)
                                            _Badge(
                                              icon: Icons.calendar_today,
                                              color: Colors.purpleAccent,
                                              text:
                                                  '${media.season?.name.toUpperCase() ?? ""} ${media.seasonYear}'
                                                      .trim(),
                                            ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),

                            const SizedBox(height: 20),

                            // Stats Grid
                            Container(
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                color: const Color(0xFF1E293B),
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(
                                    color: Colors.white
                                        .withValues(alpha: 0.05)),
                              ),
                              child: Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceAround,
                                children: [
                                  _StatItem(
                                    label: 'Episodes',
                                    value: '${media.episodes ?? "?"}',
                                  ),
                                  _StatItem(
                                    label: 'Duration',
                                    value: media.duration != null
                                        ? '${media.duration}m'
                                        : '?',
                                  ),
                                  _StatItem(
                                    label: 'Avg Score',
                                    value: media.averageScore != null
                                        ? '${media.averageScore}%'
                                        : 'N/A',
                                    color: Colors.amber,
                                  ),
                                  _StatItem(
                                    label: 'Favorites',
                                    value: media.favourites != null
                                        ? '${(media.favourites! / 1000).toStringAsFixed(1)}k'
                                        : '0',
                                    color: Colors.pinkAccent,
                                  ),
                                ],
                              ),
                            ),

                            const SizedBox(height: 20),

                            // Genres Section
                            if (genres.isNotEmpty) ...[
                              const Text(
                                'Genres',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: genres.map((g) {
                                  return Chip(
                                    label: Text(g),
                                    backgroundColor: const Color(0xFF1E293B),
                                    labelStyle: const TextStyle(
                                      color: Color(0xFF38BDF8),
                                      fontSize: 12,
                                    ),
                                    side: BorderSide.none,
                                    shape: RoundedRectangleBorder(
                                      borderRadius:
                                          BorderRadius.circular(16),
                                    ),
                                  );
                                }).toList(),
                              ),
                              const SizedBox(height: 20),
                            ],

                            // Description Section
                            const Text(
                              'Synopsis',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              description,
                              style: TextStyle(
                                color: Colors.grey.shade300,
                                fontSize: 14,
                                height: 1.6,
                              ),
                            ),
                            const SizedBox(height: 40),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String text;

  const _Badge({required this.icon, required this.color, required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Text(
            text,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _StatItem extends StatelessWidget {
  final String label;
  final String value;
  final Color? color;

  const _StatItem({required this.label, required this.value, this.color});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          value,
          style: TextStyle(
            color: color ?? Colors.white,
            fontSize: 16,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: TextStyle(
            color: Colors.grey.shade500,
            fontSize: 11,
          ),
        ),
      ],
    );
  }
}
