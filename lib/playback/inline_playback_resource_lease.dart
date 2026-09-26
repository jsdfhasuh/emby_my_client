class InlinePlaybackResourceLease {
  InlinePlaybackResourceLease();

  static final InlinePlaybackResourceLease application =
      InlinePlaybackResourceLease();

  int _generation = 0;
  bool _acquired = false;
  bool _poisoned = false;

  bool get isPoisoned => _poisoned;
  bool get isAcquired => _acquired;

  InlinePlaybackResourceLeaseHandle acquire() {
    if (_poisoned) {
      throw StateError(
        'Inline playback is quarantined because native player disposal '
        'was not confirmed',
      );
    }
    if (_acquired) {
      throw StateError('An inline playback native resource is already active');
    }
    _acquired = true;
    _generation++;
    return InlinePlaybackResourceLeaseHandle._(this, _generation);
  }

  void release(InlinePlaybackResourceLeaseHandle handle) {
    if (!_owns(handle) || _poisoned) return;
    _acquired = false;
  }

  void poison(InlinePlaybackResourceLeaseHandle handle) {
    if (!_owns(handle)) return;
    _poisoned = true;
    _acquired = true;
  }

  bool _owns(InlinePlaybackResourceLeaseHandle handle) =>
      identical(handle._owner, this) &&
      handle._generation == _generation &&
      _acquired;
}

class InlinePlaybackResourceLeaseHandle {
  const InlinePlaybackResourceLeaseHandle._(this._owner, this._generation);

  final InlinePlaybackResourceLease _owner;
  final int _generation;

  bool get isPoisoned => _owner.isPoisoned;

  void ensureCanCreatePlayer() {
    if (!_owner._owns(this) || _owner.isPoisoned) {
      throw StateError(
        'Inline playback native resource lease is stale or quarantined',
      );
    }
  }
}
