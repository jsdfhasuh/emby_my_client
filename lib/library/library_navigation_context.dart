import 'package:flutter/foundation.dart';

import '../models/emby_models.dart';
import 'library_content_profile.dart';

@immutable
class LibraryBrowseOrigin {
  const LibraryBrowseOrigin({required this.rootView, required this.profile});

  final EmbyItem rootView;
  final LibraryContentProfile profile;

  bool get isValid => rootView.id.trim().isNotEmpty;
}
