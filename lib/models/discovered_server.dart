import 'dart:io';

class DiscoveredServer {
  const DiscoveredServer({
    required this.id,
    required this.name,
    required this.address,
  });

  final String id;
  final String name;
  final String address;

  static DiscoveredServer? fromJson(
    Map<String, dynamic> json, {
    InternetAddress? sourceAddress,
  }) {
    final id = json['Id']?.toString().trim() ?? '';
    final rawAddress = json['Address']?.toString();
    final address = normalizeAddress(rawAddress, sourceAddress: sourceAddress);
    if (id.isEmpty || address == null) return null;
    final name = json['Name']?.toString().trim();
    return DiscoveredServer(
      id: id,
      name: name == null || name.isEmpty ? 'Emby' : name,
      address: address,
    );
  }

  static String? normalizeAddress(
    String? input, {
    InternetAddress? sourceAddress,
  }) {
    var value = input?.trim() ?? '';
    if (value.isEmpty) return null;
    if (!value.contains('://')) value = 'http://$value';
    final uri = Uri.tryParse(value);
    if (uri == null ||
        !uri.hasAuthority ||
        (uri.scheme.toLowerCase() != 'http' &&
            uri.scheme.toLowerCase() != 'https')) {
      return null;
    }

    var host = uri.host;
    if ((host == '0.0.0.0' ||
            host == '127.0.0.1' ||
            host.toLowerCase() == 'localhost') &&
        sourceAddress != null) {
      host = sourceAddress.address;
    }
    if (host.isEmpty) return null;

    final path = uri.path.replaceFirst(RegExp(r'/+$'), '');
    final isDefaultPort =
        uri.hasPort &&
        ((uri.scheme.toLowerCase() == 'http' && uri.port == 80) ||
            (uri.scheme.toLowerCase() == 'https' && uri.port == 443));
    return uri
        .replace(
          scheme: uri.scheme.toLowerCase(),
          host: host.toLowerCase(),
          port: isDefaultPort ? null : (uri.hasPort ? uri.port : null),
          path: path,
          query: null,
          fragment: null,
        )
        .toString();
  }
}
