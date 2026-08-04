import 'package:emby_my_client/data/emby_api.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('recognizes required local IPv4 and IPv6 address ranges', () {
    for (final address in [
      'localhost:8096',
      '127.0.0.1:8096',
      '10.20.30.40:8096',
      '172.16.0.1:8096',
      '172.31.255.254:8096',
      '192.168.1.20:8096',
      '[::1]:8096',
      '[fe80::1]:8096',
      '[fc00::1]:8096',
    ]) {
      expect(isLocalNetworkAddress(address), isTrue, reason: address);
    }
  });

  test('does not classify public addresses as local', () {
    expect(isLocalNetworkAddress('https://emby.example.com'), isFalse);
    expect(isLocalNetworkAddress('8.8.8.8:8096'), isFalse);
    expect(isLocalNetworkAddress('172.15.255.255:8096'), isFalse);
    expect(isLocalNetworkAddress('172.32.0.1:8096'), isFalse);
  });

  test('only connection failures are eligible for local network recovery', () {
    const localConnection = EmbyApiException(
      'connection failed',
      serverUrl: 'http://192.168.1.20:8096',
      isConnectionFailure: true,
    );
    const localHttpError = EmbyApiException(
      'unauthorized',
      statusCode: 401,
      serverUrl: 'http://192.168.1.20:8096',
    );
    const publicConnection = EmbyApiException(
      'connection failed',
      serverUrl: 'https://emby.example.com',
      isConnectionFailure: true,
    );

    expect(localConnection.isLocalNetworkConnectionFailure, isTrue);
    expect(localHttpError.isLocalNetworkConnectionFailure, isFalse);
    expect(publicConnection.isLocalNetworkConnectionFailure, isFalse);
  });
}
