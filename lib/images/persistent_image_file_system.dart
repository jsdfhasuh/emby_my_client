import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

/// Separate from downloaded media/assets: ordinary image eviction and clearing
/// can never remove a downloaded video's required files.
class PersistentImageFileSystem implements FileSystem {
  PersistentImageFileSystem({this.directoryResolver});
  final Future<String> Function()? directoryResolver;
  late final Future<FileSystem> _delegate = _createDelegate();

  @override
  createFile(String name) async {
    if (path.basename(name) != name || name == '.' || name == '..') {
      throw const FormatException('unsafeImageCachePath');
    }
    return (await _delegate).createFile(name);
  }

  Future<FileSystem> _createDelegate() async {
    final root = directoryResolver != null
        ? await directoryResolver!()
        : path.join(
            (await getApplicationSupportDirectory()).path,
            'browse-images-v2',
          );
    // IOFileSystem joins its key to the temporary directory. An absolute key
    // replaces that prefix, keeping these files in application support. Reuse
    // its public interface without depending directly on its file package.
    return IOFileSystem(path.absolute(root));
  }
}
