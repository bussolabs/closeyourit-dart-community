import 'breadcrumb.dart';

/// Breadcrumb ring buffer: keeps the last [maxSize], drops the oldest.
class BreadcrumbBuffer {
  BreadcrumbBuffer({this.maxSize = 100});

  /// Maximum capacity; beyond it, every `add` removes the oldest.
  final int maxSize;

  final List<Breadcrumb> _items = <Breadcrumb>[];

  /// Number of breadcrumbs currently buffered.
  int get length => _items.length;

  /// `true` if empty.
  bool get isEmpty => _items.isEmpty;

  /// Adds a breadcrumb, evicting the oldest beyond [maxSize].
  void add(Breadcrumb crumb) {
    if (maxSize <= 0) return;
    _items.add(crumb);
    while (_items.length > maxSize) {
      _items.removeAt(0);
    }
  }

  /// Clears the buffer.
  void clear() => _items.clear();

  /// Immutable copy of the breadcrumbs in chronological order.
  List<Breadcrumb> toList() => List.unmodifiable(_items);

  /// Serializes to `{values: [...]}` (Sentry format), or `null` if empty.
  Map<String, Object?>? toJson() {
    if (_items.isEmpty) return null;
    return {'values': _items.map((c) => c.toJson()).toList()};
  }
}
