// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint, type=warning, deprecated_member_use, deprecated_member_use_from_same_package
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'anime_list_event.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$AnimeListEvent {





@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is AnimeListEvent);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
    return 'AnimeListEvent()';
}


}

/// @nodoc
class $AnimeListEventCopyWith<$Res>  {
$AnimeListEventCopyWith(AnimeListEvent _, $Res Function(AnimeListEvent) __);
}


/// Adds pattern-matching-related methods to [AnimeListEvent].
extension AnimeListEventPatterns on AnimeListEvent {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( AnimeListStarted value)?  started,TResult Function( AnimeListFetchNext value)?  fetchNext,TResult Function( AnimeListRefreshed value)?  refreshed,TResult Function( AnimeListSearchChanged value)?  searchChanged,TResult Function( AnimeListGenreChanged value)?  genreChanged,TResult Function( AnimeListSortChanged value)?  sortChanged,required TResult orElse(),}){
final _that = this;
switch (_that) {
case AnimeListStarted() when started != null:
return started(_that);case AnimeListFetchNext() when fetchNext != null:
return fetchNext(_that);case AnimeListRefreshed() when refreshed != null:
return refreshed(_that);case AnimeListSearchChanged() when searchChanged != null:
return searchChanged(_that);case AnimeListGenreChanged() when genreChanged != null:
return genreChanged(_that);case AnimeListSortChanged() when sortChanged != null:
return sortChanged(_that);case _:
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

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( AnimeListStarted value)  started,required TResult Function( AnimeListFetchNext value)  fetchNext,required TResult Function( AnimeListRefreshed value)  refreshed,required TResult Function( AnimeListSearchChanged value)  searchChanged,required TResult Function( AnimeListGenreChanged value)  genreChanged,required TResult Function( AnimeListSortChanged value)  sortChanged,}){
final _that = this;
switch (_that) {
case AnimeListStarted():
return started(_that);case AnimeListFetchNext():
return fetchNext(_that);case AnimeListRefreshed():
return refreshed(_that);case AnimeListSearchChanged():
return searchChanged(_that);case AnimeListGenreChanged():
return genreChanged(_that);case AnimeListSortChanged():
return sortChanged(_that);case _:
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( AnimeListStarted value)?  started,TResult? Function( AnimeListFetchNext value)?  fetchNext,TResult? Function( AnimeListRefreshed value)?  refreshed,TResult? Function( AnimeListSearchChanged value)?  searchChanged,TResult? Function( AnimeListGenreChanged value)?  genreChanged,TResult? Function( AnimeListSortChanged value)?  sortChanged,}){
final _that = this;
switch (_that) {
case AnimeListStarted() when started != null:
return started(_that);case AnimeListFetchNext() when fetchNext != null:
return fetchNext(_that);case AnimeListRefreshed() when refreshed != null:
return refreshed(_that);case AnimeListSearchChanged() when searchChanged != null:
return searchChanged(_that);case AnimeListGenreChanged() when genreChanged != null:
return genreChanged(_that);case AnimeListSortChanged() when sortChanged != null:
return sortChanged(_that);case _:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function()?  started,TResult Function()?  fetchNext,TResult Function()?  refreshed,TResult Function( String query)?  searchChanged,TResult Function( String? genre)?  genreChanged,TResult Function( MediaSort sort)?  sortChanged,required TResult orElse(),}) {final _that = this;
switch (_that) {
case AnimeListStarted() when started != null:
return started();case AnimeListFetchNext() when fetchNext != null:
return fetchNext();case AnimeListRefreshed() when refreshed != null:
return refreshed();case AnimeListSearchChanged() when searchChanged != null:
return searchChanged(_that.query);case AnimeListGenreChanged() when genreChanged != null:
return genreChanged(_that.genre);case AnimeListSortChanged() when sortChanged != null:
return sortChanged(_that.sort);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function()  started,required TResult Function()  fetchNext,required TResult Function()  refreshed,required TResult Function( String query)  searchChanged,required TResult Function( String? genre)  genreChanged,required TResult Function( MediaSort sort)  sortChanged,}) {final _that = this;
switch (_that) {
case AnimeListStarted():
return started();case AnimeListFetchNext():
return fetchNext();case AnimeListRefreshed():
return refreshed();case AnimeListSearchChanged():
return searchChanged(_that.query);case AnimeListGenreChanged():
return genreChanged(_that.genre);case AnimeListSortChanged():
return sortChanged(_that.sort);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function()?  started,TResult? Function()?  fetchNext,TResult? Function()?  refreshed,TResult? Function( String query)?  searchChanged,TResult? Function( String? genre)?  genreChanged,TResult? Function( MediaSort sort)?  sortChanged,}) {final _that = this;
switch (_that) {
case AnimeListStarted() when started != null:
return started();case AnimeListFetchNext() when fetchNext != null:
return fetchNext();case AnimeListRefreshed() when refreshed != null:
return refreshed();case AnimeListSearchChanged() when searchChanged != null:
return searchChanged(_that.query);case AnimeListGenreChanged() when genreChanged != null:
return genreChanged(_that.genre);case AnimeListSortChanged() when sortChanged != null:
return sortChanged(_that.sort);case _:
  return null;

}
}

}

/// @nodoc


class AnimeListStarted implements AnimeListEvent {
  const AnimeListStarted();
  






@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is AnimeListStarted);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
    return 'AnimeListEvent.started()';
}


}




/// @nodoc


class AnimeListFetchNext implements AnimeListEvent {
  const AnimeListFetchNext();
  






@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is AnimeListFetchNext);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
    return 'AnimeListEvent.fetchNext()';
}


}




/// @nodoc


class AnimeListRefreshed implements AnimeListEvent {
  const AnimeListRefreshed();
  






@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is AnimeListRefreshed);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
    return 'AnimeListEvent.refreshed()';
}


}




/// @nodoc


class AnimeListSearchChanged implements AnimeListEvent {
  const AnimeListSearchChanged(this.query);
  

 final  String query;

/// Create a copy of AnimeListEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$AnimeListSearchChangedCopyWith<AnimeListSearchChanged> get copyWith => _$AnimeListSearchChangedCopyWithImpl<AnimeListSearchChanged>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is AnimeListSearchChanged&&(identical(other.query, query) || other.query == query));
}


@override
int get hashCode {
    return Object.hash(runtimeType,query);
}

@override
String toString() {
    return 'AnimeListEvent.searchChanged(query: $query)';
}


}

/// @nodoc
abstract mixin class $AnimeListSearchChangedCopyWith<$Res> implements $AnimeListEventCopyWith<$Res> {
  factory $AnimeListSearchChangedCopyWith(AnimeListSearchChanged value, $Res Function(AnimeListSearchChanged) _then) = _$AnimeListSearchChangedCopyWithImpl;
@useResult
$Res call({
 String query
});




}
/// @nodoc
class _$AnimeListSearchChangedCopyWithImpl<$Res>
    implements $AnimeListSearchChangedCopyWith<$Res> {
  _$AnimeListSearchChangedCopyWithImpl(this._self, this._then);

  final AnimeListSearchChanged _self;
  final $Res Function(AnimeListSearchChanged) _then;

/// Create a copy of AnimeListEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? query = null,}) {
  return _then(AnimeListSearchChanged(
null == query ? _self.query : query // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class AnimeListGenreChanged implements AnimeListEvent {
  const AnimeListGenreChanged(this.genre);
  

 final  String? genre;

/// Create a copy of AnimeListEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$AnimeListGenreChangedCopyWith<AnimeListGenreChanged> get copyWith => _$AnimeListGenreChangedCopyWithImpl<AnimeListGenreChanged>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is AnimeListGenreChanged&&(identical(other.genre, genre) || other.genre == genre));
}


@override
int get hashCode {
    return Object.hash(runtimeType,genre);
}

@override
String toString() {
    return 'AnimeListEvent.genreChanged(genre: $genre)';
}


}

/// @nodoc
abstract mixin class $AnimeListGenreChangedCopyWith<$Res> implements $AnimeListEventCopyWith<$Res> {
  factory $AnimeListGenreChangedCopyWith(AnimeListGenreChanged value, $Res Function(AnimeListGenreChanged) _then) = _$AnimeListGenreChangedCopyWithImpl;
@useResult
$Res call({
 String? genre
});




}
/// @nodoc
class _$AnimeListGenreChangedCopyWithImpl<$Res>
    implements $AnimeListGenreChangedCopyWith<$Res> {
  _$AnimeListGenreChangedCopyWithImpl(this._self, this._then);

  final AnimeListGenreChanged _self;
  final $Res Function(AnimeListGenreChanged) _then;

/// Create a copy of AnimeListEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? genre = freezed,}) {
  return _then(AnimeListGenreChanged(
freezed == genre ? _self.genre : genre // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}


}

/// @nodoc


class AnimeListSortChanged implements AnimeListEvent {
  const AnimeListSortChanged(this.sort);
  

 final  MediaSort sort;

/// Create a copy of AnimeListEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$AnimeListSortChangedCopyWith<AnimeListSortChanged> get copyWith => _$AnimeListSortChangedCopyWithImpl<AnimeListSortChanged>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is AnimeListSortChanged&&(identical(other.sort, sort) || other.sort == sort));
}


@override
int get hashCode {
    return Object.hash(runtimeType,sort);
}

@override
String toString() {
    return 'AnimeListEvent.sortChanged(sort: $sort)';
}


}

/// @nodoc
abstract mixin class $AnimeListSortChangedCopyWith<$Res> implements $AnimeListEventCopyWith<$Res> {
  factory $AnimeListSortChangedCopyWith(AnimeListSortChanged value, $Res Function(AnimeListSortChanged) _then) = _$AnimeListSortChangedCopyWithImpl;
@useResult
$Res call({
 MediaSort sort
});




}
/// @nodoc
class _$AnimeListSortChangedCopyWithImpl<$Res>
    implements $AnimeListSortChangedCopyWith<$Res> {
  _$AnimeListSortChangedCopyWithImpl(this._self, this._then);

  final AnimeListSortChanged _self;
  final $Res Function(AnimeListSortChanged) _then;

/// Create a copy of AnimeListEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? sort = null,}) {
  return _then(AnimeListSortChanged(
null == sort ? _self.sort : sort // ignore: cast_nullable_to_non_nullable
as MediaSort,
  ));
}


}

// dart format on
