// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint, type=warning, deprecated_member_use, deprecated_member_use_from_same_package
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'anime_list_state.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$AnimeListState {

 List<GetAnimePagePageMediaModel> get items; bool get isLoading; bool get isLoadingMore; bool get hasMore; String? get errorMessage; String get searchQuery; String? get selectedGenre; MediaSort get currentSort; List<String> get availableGenres; bool get isLoadingGenres;
/// Create a copy of AnimeListState
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$AnimeListStateCopyWith<AnimeListState> get copyWith => _$AnimeListStateCopyWithImpl<AnimeListState>(this as AnimeListState, _$identity);



@override
bool operator ==(Object other) {
  final _this = this as AnimeListState;
  return identical(this, other) || (other.runtimeType == runtimeType&&other is AnimeListState&&const DeepCollectionEquality().equals(other.items, _this.items)&&(identical(other.isLoading, _this.isLoading) || other.isLoading == _this.isLoading)&&(identical(other.isLoadingMore, _this.isLoadingMore) || other.isLoadingMore == _this.isLoadingMore)&&(identical(other.hasMore, _this.hasMore) || other.hasMore == _this.hasMore)&&(identical(other.errorMessage, _this.errorMessage) || other.errorMessage == _this.errorMessage)&&(identical(other.searchQuery, _this.searchQuery) || other.searchQuery == _this.searchQuery)&&(identical(other.selectedGenre, _this.selectedGenre) || other.selectedGenre == _this.selectedGenre)&&(identical(other.currentSort, _this.currentSort) || other.currentSort == _this.currentSort)&&const DeepCollectionEquality().equals(other.availableGenres, _this.availableGenres)&&(identical(other.isLoadingGenres, _this.isLoadingGenres) || other.isLoadingGenres == _this.isLoadingGenres));
}


@override
int get hashCode {
  final _this = this as AnimeListState;
  return Object.hash(runtimeType,const DeepCollectionEquality().hash(_this.items),_this.isLoading,_this.isLoadingMore,_this.hasMore,_this.errorMessage,_this.searchQuery,_this.selectedGenre,_this.currentSort,const DeepCollectionEquality().hash(_this.availableGenres),_this.isLoadingGenres);
}

@override
String toString() {
  final _this = this as AnimeListState;
  return 'AnimeListState(items: ${_this.items}, isLoading: ${_this.isLoading}, isLoadingMore: ${_this.isLoadingMore}, hasMore: ${_this.hasMore}, errorMessage: ${_this.errorMessage}, searchQuery: ${_this.searchQuery}, selectedGenre: ${_this.selectedGenre}, currentSort: ${_this.currentSort}, availableGenres: ${_this.availableGenres}, isLoadingGenres: ${_this.isLoadingGenres})';
}


}

/// @nodoc
abstract mixin class $AnimeListStateCopyWith<$Res>  {
  factory $AnimeListStateCopyWith(AnimeListState value, $Res Function(AnimeListState) _then) = _$AnimeListStateCopyWithImpl;
@useResult
$Res call({
 List<GetAnimePagePageMediaModel> items, bool isLoading, bool isLoadingMore, bool hasMore, String? errorMessage, String searchQuery, String? selectedGenre, MediaSort currentSort, List<String> availableGenres, bool isLoadingGenres
});




}
/// @nodoc
class _$AnimeListStateCopyWithImpl<$Res>
    implements $AnimeListStateCopyWith<$Res> {
  _$AnimeListStateCopyWithImpl(this._self, this._then);

  final AnimeListState _self;
  final $Res Function(AnimeListState) _then;

/// Create a copy of AnimeListState
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? items = null,Object? isLoading = null,Object? isLoadingMore = null,Object? hasMore = null,Object? errorMessage = freezed,Object? searchQuery = null,Object? selectedGenre = freezed,Object? currentSort = null,Object? availableGenres = null,Object? isLoadingGenres = null,}) {
  return _then(AnimeListState(
items: null == items ? _self.items : items // ignore: cast_nullable_to_non_nullable
as List<GetAnimePagePageMediaModel>,isLoading: null == isLoading ? _self.isLoading : isLoading // ignore: cast_nullable_to_non_nullable
as bool,isLoadingMore: null == isLoadingMore ? _self.isLoadingMore : isLoadingMore // ignore: cast_nullable_to_non_nullable
as bool,hasMore: null == hasMore ? _self.hasMore : hasMore // ignore: cast_nullable_to_non_nullable
as bool,errorMessage: freezed == errorMessage ? _self.errorMessage : errorMessage // ignore: cast_nullable_to_non_nullable
as String?,searchQuery: null == searchQuery ? _self.searchQuery : searchQuery // ignore: cast_nullable_to_non_nullable
as String,selectedGenre: freezed == selectedGenre ? _self.selectedGenre : selectedGenre // ignore: cast_nullable_to_non_nullable
as String?,currentSort: null == currentSort ? _self.currentSort : currentSort // ignore: cast_nullable_to_non_nullable
as MediaSort,availableGenres: null == availableGenres ? _self.availableGenres : availableGenres // ignore: cast_nullable_to_non_nullable
as List<String>,isLoadingGenres: null == isLoadingGenres ? _self.isLoadingGenres : isLoadingGenres // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}

}


/// Adds pattern-matching-related methods to [AnimeListState].
extension AnimeListStatePatterns on AnimeListState {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _AnimeListState value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _AnimeListState() when $default != null:
return $default(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _AnimeListState value)  $default,){
final _that = this;
switch (_that) {
case _AnimeListState():
return $default(_that);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _AnimeListState value)?  $default,){
final _that = this;
switch (_that) {
case _AnimeListState() when $default != null:
return $default(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( List<GetAnimePagePageMediaModel> items,  bool isLoading,  bool isLoadingMore,  bool hasMore,  String? errorMessage,  String searchQuery,  String? selectedGenre,  MediaSort currentSort,  List<String> availableGenres,  bool isLoadingGenres)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _AnimeListState() when $default != null:
return $default(_that.items,_that.isLoading,_that.isLoadingMore,_that.hasMore,_that.errorMessage,_that.searchQuery,_that.selectedGenre,_that.currentSort,_that.availableGenres,_that.isLoadingGenres);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( List<GetAnimePagePageMediaModel> items,  bool isLoading,  bool isLoadingMore,  bool hasMore,  String? errorMessage,  String searchQuery,  String? selectedGenre,  MediaSort currentSort,  List<String> availableGenres,  bool isLoadingGenres)  $default,) {final _that = this;
switch (_that) {
case _AnimeListState():
return $default(_that.items,_that.isLoading,_that.isLoadingMore,_that.hasMore,_that.errorMessage,_that.searchQuery,_that.selectedGenre,_that.currentSort,_that.availableGenres,_that.isLoadingGenres);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( List<GetAnimePagePageMediaModel> items,  bool isLoading,  bool isLoadingMore,  bool hasMore,  String? errorMessage,  String searchQuery,  String? selectedGenre,  MediaSort currentSort,  List<String> availableGenres,  bool isLoadingGenres)?  $default,) {final _that = this;
switch (_that) {
case _AnimeListState() when $default != null:
return $default(_that.items,_that.isLoading,_that.isLoadingMore,_that.hasMore,_that.errorMessage,_that.searchQuery,_that.selectedGenre,_that.currentSort,_that.availableGenres,_that.isLoadingGenres);case _:
  return null;

}
}

}

/// @nodoc


class _AnimeListState implements AnimeListState {
  const _AnimeListState({ List<GetAnimePagePageMediaModel> items = const [], this.isLoading = true, this.isLoadingMore = false, this.hasMore = true, this.errorMessage, this.searchQuery = '', this.selectedGenre, this.currentSort = MediaSort.popularityDesc,  List<String> availableGenres = const [], this.isLoadingGenres = true}): _items = items,_availableGenres = availableGenres;
  

 final  List<GetAnimePagePageMediaModel> _items;
@override@JsonKey() List<GetAnimePagePageMediaModel> get items {
  if (_items is EqualUnmodifiableListView) return _items;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_items);
}

@override@JsonKey() final  bool isLoading;
@override@JsonKey() final  bool isLoadingMore;
@override@JsonKey() final  bool hasMore;
@override final  String? errorMessage;
@override@JsonKey() final  String searchQuery;
@override final  String? selectedGenre;
@override@JsonKey() final  MediaSort currentSort;
 final  List<String> _availableGenres;
@override@JsonKey() List<String> get availableGenres {
  if (_availableGenres is EqualUnmodifiableListView) return _availableGenres;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_availableGenres);
}

@override@JsonKey() final  bool isLoadingGenres;

/// Create a copy of AnimeListState
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$AnimeListStateCopyWith<_AnimeListState> get copyWith => __$AnimeListStateCopyWithImpl<_AnimeListState>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is _AnimeListState&&const DeepCollectionEquality().equals(other.items, _items)&&(identical(other.isLoading, isLoading) || other.isLoading == isLoading)&&(identical(other.isLoadingMore, isLoadingMore) || other.isLoadingMore == isLoadingMore)&&(identical(other.hasMore, hasMore) || other.hasMore == hasMore)&&(identical(other.errorMessage, errorMessage) || other.errorMessage == errorMessage)&&(identical(other.searchQuery, searchQuery) || other.searchQuery == searchQuery)&&(identical(other.selectedGenre, selectedGenre) || other.selectedGenre == selectedGenre)&&(identical(other.currentSort, currentSort) || other.currentSort == currentSort)&&const DeepCollectionEquality().equals(other.availableGenres, _availableGenres)&&(identical(other.isLoadingGenres, isLoadingGenres) || other.isLoadingGenres == isLoadingGenres));
}


@override
int get hashCode {
    return Object.hash(runtimeType,const DeepCollectionEquality().hash(_items),isLoading,isLoadingMore,hasMore,errorMessage,searchQuery,selectedGenre,currentSort,const DeepCollectionEquality().hash(_availableGenres),isLoadingGenres);
}

@override
String toString() {
    return 'AnimeListState(items: $items, isLoading: $isLoading, isLoadingMore: $isLoadingMore, hasMore: $hasMore, errorMessage: $errorMessage, searchQuery: $searchQuery, selectedGenre: $selectedGenre, currentSort: $currentSort, availableGenres: $availableGenres, isLoadingGenres: $isLoadingGenres)';
}


}

/// @nodoc
abstract mixin class _$AnimeListStateCopyWith<$Res> implements $AnimeListStateCopyWith<$Res> {
  factory _$AnimeListStateCopyWith(_AnimeListState value, $Res Function(_AnimeListState) _then) = __$AnimeListStateCopyWithImpl;
@override @useResult
$Res call({
 List<GetAnimePagePageMediaModel> items, bool isLoading, bool isLoadingMore, bool hasMore, String? errorMessage, String searchQuery, String? selectedGenre, MediaSort currentSort, List<String> availableGenres, bool isLoadingGenres
});




}
/// @nodoc
class __$AnimeListStateCopyWithImpl<$Res>
    implements _$AnimeListStateCopyWith<$Res> {
  __$AnimeListStateCopyWithImpl(this._self, this._then);

  final _AnimeListState _self;
  final $Res Function(_AnimeListState) _then;

/// Create a copy of AnimeListState
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? items = null,Object? isLoading = null,Object? isLoadingMore = null,Object? hasMore = null,Object? errorMessage = freezed,Object? searchQuery = null,Object? selectedGenre = freezed,Object? currentSort = null,Object? availableGenres = null,Object? isLoadingGenres = null,}) {
  return _then(_AnimeListState(
items: null == items ? _self._items : items // ignore: cast_nullable_to_non_nullable
as List<GetAnimePagePageMediaModel>,isLoading: null == isLoading ? _self.isLoading : isLoading // ignore: cast_nullable_to_non_nullable
as bool,isLoadingMore: null == isLoadingMore ? _self.isLoadingMore : isLoadingMore // ignore: cast_nullable_to_non_nullable
as bool,hasMore: null == hasMore ? _self.hasMore : hasMore // ignore: cast_nullable_to_non_nullable
as bool,errorMessage: freezed == errorMessage ? _self.errorMessage : errorMessage // ignore: cast_nullable_to_non_nullable
as String?,searchQuery: null == searchQuery ? _self.searchQuery : searchQuery // ignore: cast_nullable_to_non_nullable
as String,selectedGenre: freezed == selectedGenre ? _self.selectedGenre : selectedGenre // ignore: cast_nullable_to_non_nullable
as String?,currentSort: null == currentSort ? _self.currentSort : currentSort // ignore: cast_nullable_to_non_nullable
as MediaSort,availableGenres: null == availableGenres ? _self._availableGenres : availableGenres // ignore: cast_nullable_to_non_nullable
as List<String>,isLoadingGenres: null == isLoadingGenres ? _self.isLoadingGenres : isLoadingGenres // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}


}

// dart format on
