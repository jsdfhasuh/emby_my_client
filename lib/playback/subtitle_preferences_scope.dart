import 'package:flutter/widgets.dart';
import 'subtitle_preferences_repository.dart';

class SubtitlePreferencesRepositoryScope extends InheritedWidget {
  const SubtitlePreferencesRepositoryScope({
    super.key,
    required this.repository,
    required super.child,
  });
  final SubtitlePreferencesRepository repository;
  static SubtitlePreferencesRepository of(BuildContext context) =>
      context
          .getInheritedWidgetOfExactType<SubtitlePreferencesRepositoryScope>()
          ?.repository ??
      SubtitlePreferencesRepository.instance;
  @override
  bool updateShouldNotify(SubtitlePreferencesRepositoryScope oldWidget) =>
      !identical(repository, oldWidget.repository);
}
