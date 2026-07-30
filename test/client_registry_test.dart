import 'package:emby_my_client/core/server_scope.dart';
import 'package:emby_my_client/data/client_registry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('registers and disposes scoped clients exactly once', () async {
    final disposed = <String>[];
    final registry = ClientRegistry<_TestClient>(
      disposeClient: (client) async {
        client.disposed = true;
        disposed.add(client.name);
      },
    );
    final first = _TestClient('first');
    final replacement = _TestClient('replacement');
    final other = _TestClient('other');

    registry.register(_firstScope, first);
    registry.register(_secondScope, other);

    expect(registry.requireClient(_firstScope), same(first));
    expect(registry.scopes, containsAll([_firstScope, _secondScope]));
    expect(
      () => registry.register(_firstScope, _TestClient('duplicate')),
      throwsStateError,
    );

    await registry.replace(_firstScope, replacement);
    expect(first.disposed, isTrue);
    expect(registry.requireClient(_firstScope), same(replacement));

    await registry.unregister(_secondScope);
    await registry.unregister(_secondScope);
    expect(other.disposed, isTrue);

    await registry.dispose();
    await registry.dispose();
    expect(replacement.disposed, isTrue);
    expect(disposed, ['first', 'other', 'replacement']);
    expect(
      () => registry.register(_firstScope, _TestClient('late')),
      throwsStateError,
    );
  });
}

class _TestClient {
  _TestClient(this.name);

  final String name;
  bool disposed = false;
}

const _firstScope = ServerScope(serverId: 'server-1', userId: 'user-1');
const _secondScope = ServerScope(serverId: 'server-1', userId: 'user-2');
