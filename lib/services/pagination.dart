/// A single page of results plus whether more exist and the cursor to fetch
/// the next page.
///
/// For keyset (created_at) pagination [nextCursor] is the ISO-8601 timestamp of
/// the last item; pass it back as `before`. For offset pagination [nextCursor]
/// is the next row offset as a string.
class Paged<T> {
  final List<T> items;
  final bool hasMore;
  final String? nextCursor;

  const Paged({required this.items, required this.hasMore, this.nextCursor});

  static Paged<T> empty<T>() =>
      Paged<T>(items: const [], hasMore: false, nextCursor: null);
}

/// Default page size used across paginated queries.
const int kPageSize = 13;
