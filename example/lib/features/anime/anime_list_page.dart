import 'dart:async';
import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../di/injection.dart';
import '../../graphql/generated/anime.gql.dart';
import '../../router/app_router.gr.dart';
import 'bloc/anime_list_bloc.dart';

@RoutePage()
class AnimeListPage extends StatelessWidget {
  const AnimeListPage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => getIt<AnimeListBloc>()..add(const AnimeListEvent.started()),
      child: const _AnimeListView(),
    );
  }
}

class _AnimeListView extends StatefulWidget {
  const _AnimeListView();

  @override
  State<_AnimeListView> createState() => _AnimeListViewState();
}

class _AnimeListViewState extends State<_AnimeListView> {
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _searchController = TextEditingController();
  Timer? _debounceTimer;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 300) {
      context.read<AnimeListBloc>().add(const AnimeListEvent.fetchNext());
    }
  }

  void _onSearchChanged(String query) {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 500), () {
      context.read<AnimeListBloc>().add(AnimeListEvent.searchChanged(query));
    });
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B0F19),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0B0F19),
        elevation: 0,
        title: const Row(
          children: [
            Icon(Icons.movie_filter_rounded, color: Color(0xFF38BDF8)),
            SizedBox(width: 8),
            Text(
              'AniList Explorer',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                letterSpacing: -0.5,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.bolt_rounded),
            tooltip: 'Client optimizations demo',
            onPressed: () => context.router.push(const OptimizationsRoute()),
          ),
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Refetch page 1',
            onPressed: () => context
                .read<AnimeListBloc>()
                .add(const AnimeListEvent.refreshed()),
          ),
        ],
      ),
      body: BlocListener<AnimeListBloc, AnimeListState>(
        listenWhen: (prev, curr) =>
            curr.searchQuery.isEmpty && _searchController.text.isNotEmpty,
        listener: (context, state) {
          _searchController.clear();
        },
        child: BlocBuilder<AnimeListBloc, AnimeListState>(
          builder: (context, state) {
            return Column(
              children: [
                // 1. Search Bar
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                  child: TextField(
                    controller: _searchController,
                    onChanged: _onSearchChanged,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      hintText: 'Search anime (e.g. Attack on Titan, Naruto)...',
                      hintStyle: TextStyle(color: Colors.grey.shade500),
                      prefixIcon:
                          const Icon(Icons.search, color: Color(0xFF38BDF8)),
                      suffixIcon: _searchController.text.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.clear, color: Colors.grey),
                              onPressed: () {
                                _searchController.clear();
                                _onSearchChanged('');
                              },
                            )
                          : null,
                      filled: true,
                      fillColor: const Color(0xFF1E293B),
                      contentPadding: const EdgeInsets.symmetric(vertical: 0),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),

                // 2. Sort & Filter Row
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16.0),
                  child: Row(
                    children: [
                      const Icon(Icons.sort_rounded, size: 18, color: Colors.grey),
                      const SizedBox(width: 6),
                      DropdownButton<MediaSort>(
                        value: state.currentSort,
                        dropdownColor: const Color(0xFF1E293B),
                        style:
                            const TextStyle(color: Color(0xFF38BDF8), fontSize: 13),
                        underline: const SizedBox.shrink(),
                        items: const [
                          DropdownMenuItem(
                            value: MediaSort.popularityDesc,
                            child: Text('Most Popular'),
                          ),
                          DropdownMenuItem(
                            value: MediaSort.trendingDesc,
                            child: Text('Trending Now'),
                          ),
                          DropdownMenuItem(
                            value: MediaSort.scoreDesc,
                            child: Text('Top Rated'),
                          ),
                          DropdownMenuItem(
                            value: MediaSort.startDateDesc,
                            child: Text('Newest'),
                          ),
                        ],
                        onChanged: (val) {
                          if (val != null && val != state.currentSort) {
                            context
                                .read<AnimeListBloc>()
                                .add(AnimeListEvent.sortChanged(val));
                          }
                        },
                      ),
                      const Spacer(),
                      if (state.selectedGenre != null)
                        TextButton.icon(
                          style: TextButton.styleFrom(
                            foregroundColor: Colors.amber,
                            visualDensity: VisualDensity.compact,
                          ),
                          icon: const Icon(Icons.close, size: 14),
                          label: Text('Clear "${state.selectedGenre}"'),
                          onPressed: () {
                            context
                                .read<AnimeListBloc>()
                                .add(const AnimeListEvent.genreChanged(null));
                          },
                        ),
                    ],
                  ),
                ),

                // 3. Horizontal Genre Chips
                if (!state.isLoadingGenres && state.availableGenres.isNotEmpty)
                  SizedBox(
                    height: 38,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: state.availableGenres.length,
                      separatorBuilder: (context, index) =>
                          const SizedBox(width: 8),
                      itemBuilder: (context, index) {
                        final genre = state.availableGenres[index];
                        final isSelected = state.selectedGenre == genre;
                        return ChoiceChip(
                          label: Text(genre),
                          labelStyle: TextStyle(
                            fontSize: 12,
                            color: isSelected ? Colors.white : Colors.grey.shade400,
                            fontWeight:
                                isSelected ? FontWeight.bold : FontWeight.normal,
                          ),
                          selected: isSelected,
                          selectedColor: const Color(0xFF0284C7),
                          backgroundColor: const Color(0xFF1E293B),
                          side: BorderSide.none,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(20),
                          ),
                          onSelected: (selected) {
                            context.read<AnimeListBloc>().add(
                                  AnimeListEvent.genreChanged(
                                      selected ? genre : null),
                                );
                          },
                        );
                      },
                    ),
                  ),

                const SizedBox(height: 8),

                // 4. Grid view displaying bloc items
                Expanded(
                  child: _buildGridContent(context, state),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildGridContent(BuildContext context, AnimeListState state) {
    if (state.isLoading && state.items.isEmpty) {
      return const Center(
        child: CircularProgressIndicator(color: Color(0xFF38BDF8)),
      );
    }

    if (state.errorMessage != null && state.items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline,
                  color: Colors.redAccent, size: 48),
              const SizedBox(height: 12),
              Text(
                'Failed to load anime: ${state.errorMessage}',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70),
              ),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: () => context
                    .read<AnimeListBloc>()
                    .add(const AnimeListEvent.started()),
                icon: const Icon(Icons.refresh),
                label: const Text('Try Again'),
              ),
            ],
          ),
        ),
      );
    }

    if (state.items.isEmpty) {
      return const Center(
        child: Text(
          'No anime found matching your criteria.',
          style: TextStyle(color: Colors.grey),
        ),
      );
    }

    return RefreshIndicator(
      color: const Color(0xFF38BDF8),
      backgroundColor: const Color(0xFF1E293B),
      onRefresh: () async {
        context.read<AnimeListBloc>().add(const AnimeListEvent.refreshed());
      },
      child: GridView.builder(
        controller: _scrollController,
        padding: const EdgeInsets.all(12),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          childAspectRatio: 0.62,
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
        ),
        itemCount: state.items.length + (state.hasMore ? 2 : 0),
        itemBuilder: (context, index) {
          if (index >= state.items.length) {
            return const Card(
              color: Color(0xFF1E293B),
              child: Center(
                child:
                    CircularProgressIndicator(color: Color(0xFF38BDF8)),
              ),
            );
          }

          final media = state.items[index];
          return _AnimeCard(
            media: media,
            onTap: () {
              context.router.push(AnimeDetailsRoute(id: media.id));
            },
          );
        },
      ),
    );
  }
}

class _AnimeCard extends StatelessWidget {
  final GetAnimePagePageMediaModel media;
  final VoidCallback onTap;

  const _AnimeCard({required this.media, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final title = media.title?.english ?? media.title?.romaji ?? 'Unknown';
    final imageUrl = media.coverImage?.large ?? media.coverImage?.extraLarge;
    final score = media.averageScore;
    final episodes = media.episodes;
    final format = media.format?.name.toUpperCase() ?? '';

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF1E293B),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Poster Image
            Expanded(
              flex: 4,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (imageUrl != null)
                    Image.network(
                      imageUrl,
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stackTrace) => Container(
                        color: const Color(0xFF334155),
                        child:
                            const Icon(Icons.broken_image, color: Colors.grey),
                      ),
                    )
                  else
                    Container(
                      color: const Color(0xFF334155),
                      child: const Icon(Icons.movie, color: Colors.grey),
                    ),

                  // Score Pill
                  if (score != null)
                    Positioned(
                      top: 8,
                      right: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.75),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                              color: Colors.amber.withValues(alpha: 0.5)),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.star_rounded,
                                color: Colors.amber, size: 14),
                            const SizedBox(width: 2),
                            Text(
                              '$score%',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),

                  // Format Pill
                  if (format.isNotEmpty)
                    Positioned(
                      bottom: 8,
                      left: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: const Color(0xFF0284C7).withValues(alpha: 0.9),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          format,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),

            // Anime Info
            Expanded(
              flex: 2,
              child: Padding(
                padding: const EdgeInsets.all(8.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        height: 1.2,
                      ),
                    ),
                    Row(
                      children: [
                        if (episodes != null) ...[
                          Icon(Icons.video_library_rounded,
                              size: 12, color: Colors.grey.shade400),
                          const SizedBox(width: 3),
                          Text(
                            '$episodes ep',
                            style: TextStyle(
                              color: Colors.grey.shade400,
                              fontSize: 11,
                            ),
                          ),
                        ],
                        const Spacer(),
                        if (media.seasonYear != null)
                          Text(
                            '${media.seasonYear}',
                            style: TextStyle(
                              color: Colors.grey.shade500,
                              fontSize: 11,
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
