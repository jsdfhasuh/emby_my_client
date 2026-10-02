/// Adapts only future requests. Existing ranges keep their original offsets
/// and sizes, and samples from an earlier tier/seek cannot train a new tier.
class SourceReadAheadPolicy {
  SourceReadAheadPolicy({this.fixedRangeBytes, this.maximumConcurrency = 8});

  static const mib = 1024 * 1024;
  static const tiers = [mib, 2 * mib, 4 * mib, 6 * mib];
  static const windowBudget = 24 * mib;
  final int? fixedRangeBytes;
  final int maximumConcurrency;
  int _tier = 1;
  int _ceiling = tiers.length - 1;
  int _fastSamples = 0;
  int _consumed = 0;
  int _sampleBytes = 0, _sampleMicros = 0, _samples = 0;
  double? _previousRate;
  int generation = 0;

  int get rangeBytes => fixedRangeBytes ?? tiers[_tier];
  int concurrency(int maximum) => maximum.clamp(1, windowBudget ~/ rangeBytes);

  void reset() {
    _tier = 1;
    _ceiling = tiers.length - 1;
    _restartEvidence();
  }

  void failed() {
    _tier = 0;
    _restartEvidence();
  }

  double get _estimatedRate => _sampleMicros == 0
      ? 0
      : _sampleBytes * concurrency(maximumConcurrency) / _sampleMicros;

  void _restartEvidence({double? previousRate}) {
    generation++;
    _fastSamples = 0;
    _consumed = 0;
    _sampleBytes = _sampleMicros = _samples = 0;
    _previousRate = previousRate;
  }

  void consumed(int bytes) {
    if (fixedRangeBytes != null) return;
    _consumed += bytes;
    // Both sustained sequential consumption and successful full-sized
    // transfers are needed; a burst of speculative completions is insufficient.
    if (_tier < _ceiling && _consumed >= 4 * rangeBytes && _fastSamples >= 4) {
      final previousRate = _estimatedRate;
      _tier++;
      _restartEvidence(previousRate: previousRate);
    }
  }

  void completed({
    required int bytes,
    required Duration elapsed,
    required int sampleGeneration,
  }) {
    if (fixedRangeBytes != null || sampleGeneration != generation) return;
    if (elapsed >= const Duration(seconds: 4)) {
      if (_tier > 0) _tier--;
      _restartEvidence();
      return;
    }
    if (bytes != rangeBytes || elapsed.inMicroseconds <= 0) return;
    _sampleBytes += bytes;
    _sampleMicros += elapsed.inMicroseconds;
    _samples++;
    final previousRate = _previousRate;
    if (previousRate != null && _samples >= 4) {
      // Compare request throughput with the concurrency reduction accounted
      // for. This is an estimate, not a measurement of device-wide bandwidth.
      if (_estimatedRate < previousRate * 0.8) {
        _ceiling = --_tier;
        _restartEvidence();
        return;
      }
      _previousRate = null;
    }
    if (elapsed <= const Duration(seconds: 2)) {
      _fastSamples++;
    } else {
      _fastSamples = 0;
    }
  }
}
