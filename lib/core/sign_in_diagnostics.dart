enum SignInStage {
  preflight,
  sessionRead,
  deviceIdRead,
  deviceIdWrite,
  authenticate,
  sessionPrepare,
  sessionSave,
  activate,
  sessionDelete,
  rollback,
}

extension SignInStageCode on SignInStage {
  String get code => switch (this) {
    SignInStage.preflight => 'PREFLIGHT',
    SignInStage.sessionRead => 'SESSION_READ',
    SignInStage.deviceIdRead => 'DEVICE_ID_READ',
    SignInStage.deviceIdWrite => 'DEVICE_ID_WRITE',
    SignInStage.authenticate => 'AUTHENTICATE',
    SignInStage.sessionPrepare => 'SESSION_PREPARE',
    SignInStage.sessionSave => 'SESSION_SAVE',
    SignInStage.activate => 'ACTIVATE',
    SignInStage.sessionDelete => 'SESSION_DELETE',
    SignInStage.rollback => 'ROLLBACK',
  };
}

enum SecureStorageOperation {
  readDeviceId,
  writeDeviceId,
  readSession,
  writeSession,
  deleteSession,
}

extension SecureStorageOperationCode on SecureStorageOperation {
  String get code => switch (this) {
    SecureStorageOperation.readDeviceId => 'read_device_id',
    SecureStorageOperation.writeDeviceId => 'write_device_id',
    SecureStorageOperation.readSession => 'read_session',
    SecureStorageOperation.writeSession => 'write_session',
    SecureStorageOperation.deleteSession => 'delete_session',
  };
}

enum SecureStorageFailureReason {
  missingEntitlement,
  unavailable,
  accessDenied,
  unexpected,
}

extension SecureStorageFailureReasonCode on SecureStorageFailureReason {
  String get code => switch (this) {
    SecureStorageFailureReason.missingEntitlement =>
      'secure_storage_missing_entitlement',
    SecureStorageFailureReason.unavailable => 'secure_storage_unavailable',
    SecureStorageFailureReason.accessDenied => 'secure_storage_access_denied',
    SecureStorageFailureReason.unexpected => 'secure_storage_unexpected',
  };
}

class SecureStorageFailure implements Exception {
  const SecureStorageFailure({required this.operation, required this.reason});

  final SecureStorageOperation operation;
  final SecureStorageFailureReason reason;

  String get errorType => 'SecureStorageFailure';

  @override
  String toString() =>
      'SecureStorageFailure(${operation.code}, ${reason.code})';
}

enum SignInFailureReason {
  secureStorageMissingEntitlement,
  secureStorageUnavailable,
  secureStorageAccessDenied,
  secureStorageUnexpected,
  sessionPrepareFailed,
  sessionSaveFailed,
  activationFailed,
  alreadyInProgress,
  alreadySignedIn,
  unknown,
}

extension SignInFailureReasonCode on SignInFailureReason {
  String get code => switch (this) {
    SignInFailureReason.secureStorageMissingEntitlement =>
      'secure_storage_missing_entitlement',
    SignInFailureReason.secureStorageUnavailable =>
      'secure_storage_unavailable',
    SignInFailureReason.secureStorageAccessDenied =>
      'secure_storage_access_denied',
    SignInFailureReason.secureStorageUnexpected => 'secure_storage_unexpected',
    SignInFailureReason.sessionPrepareFailed => 'session_prepare_failed',
    SignInFailureReason.sessionSaveFailed => 'session_save_failed',
    SignInFailureReason.activationFailed => 'activation_failed',
    SignInFailureReason.alreadyInProgress => 'already_in_progress',
    SignInFailureReason.alreadySignedIn => 'already_signed_in',
    SignInFailureReason.unknown => 'unknown',
  };
}

class SignInFailure implements Exception {
  const SignInFailure({required this.stage, required this.reason});

  final SignInStage stage;
  final SignInFailureReason reason;

  String get errorType => switch (reason) {
    SignInFailureReason.secureStorageMissingEntitlement ||
    SignInFailureReason.secureStorageUnavailable ||
    SignInFailureReason.secureStorageAccessDenied ||
    SignInFailureReason.secureStorageUnexpected => 'SecureStorageFailure',
    _ => 'SignInFailure',
  };

  String get diagnosticCode => switch ((stage, reason)) {
    (
      SignInStage.deviceIdRead,
      SignInFailureReason.secureStorageMissingEntitlement,
    ) =>
      'LOGIN-DID-READ-KC-MISSING',
    (SignInStage.deviceIdRead, SignInFailureReason.secureStorageUnavailable) =>
      'LOGIN-DID-READ-KC-UNAVAILABLE',
    (SignInStage.deviceIdRead, SignInFailureReason.secureStorageAccessDenied) =>
      'LOGIN-DID-READ-KC-DENIED',
    (SignInStage.deviceIdRead, SignInFailureReason.secureStorageUnexpected) =>
      'LOGIN-DID-READ-KC-UNEXPECTED',
    (
      SignInStage.deviceIdWrite,
      SignInFailureReason.secureStorageMissingEntitlement,
    ) =>
      'LOGIN-DID-WRITE-KC-MISSING',
    (SignInStage.deviceIdWrite, SignInFailureReason.secureStorageUnavailable) =>
      'LOGIN-DID-WRITE-KC-UNAVAILABLE',
    (
      SignInStage.deviceIdWrite,
      SignInFailureReason.secureStorageAccessDenied,
    ) =>
      'LOGIN-DID-WRITE-KC-DENIED',
    (SignInStage.deviceIdWrite, SignInFailureReason.secureStorageUnexpected) =>
      'LOGIN-DID-WRITE-KC-UNEXPECTED',
    (
      SignInStage.sessionSave,
      SignInFailureReason.secureStorageMissingEntitlement,
    ) =>
      'LOGIN-SESSION-SAVE-KC-MISSING',
    (SignInStage.sessionSave, SignInFailureReason.secureStorageUnavailable) =>
      'LOGIN-SESSION-SAVE-KC-UNAVAILABLE',
    (SignInStage.sessionSave, SignInFailureReason.secureStorageAccessDenied) =>
      'LOGIN-SESSION-SAVE-KC-DENIED',
    (SignInStage.sessionSave, SignInFailureReason.secureStorageUnexpected) =>
      'LOGIN-SESSION-SAVE-KC-UNEXPECTED',
    (SignInStage.sessionPrepare, _) => 'LOGIN-SESSION-PREPARE',
    (SignInStage.activate, _) => 'LOGIN-ACTIVATE',
    _ => 'LOGIN-UNKNOWN',
  };

  static SignInFailure fromSecureStorage(
    SignInStage stage,
    SecureStorageFailure failure,
  ) => SignInFailure(
    stage: stage,
    reason: switch (failure.reason) {
      SecureStorageFailureReason.missingEntitlement =>
        SignInFailureReason.secureStorageMissingEntitlement,
      SecureStorageFailureReason.unavailable =>
        SignInFailureReason.secureStorageUnavailable,
      SecureStorageFailureReason.accessDenied =>
        SignInFailureReason.secureStorageAccessDenied,
      SecureStorageFailureReason.unexpected =>
        SignInFailureReason.secureStorageUnexpected,
    },
  );

  @override
  String toString() => 'SignInFailure(${stage.code}, ${reason.code})';
}

enum SafeDiagnosticComponent { auth, storage }

extension SafeDiagnosticComponentCode on SafeDiagnosticComponent {
  String get code => switch (this) {
    SafeDiagnosticComponent.auth => 'auth',
    SafeDiagnosticComponent.storage => 'storage',
  };
}

enum SafeDiagnosticEvent {
  signInStageStart,
  signInStageSuccess,
  signInFailure,
  sessionRestoreFailure,
  sessionDeleteFailure,
}

extension SafeDiagnosticEventCode on SafeDiagnosticEvent {
  String get code => switch (this) {
    SafeDiagnosticEvent.signInStageStart => 'sign_in_stage_start',
    SafeDiagnosticEvent.signInStageSuccess => 'sign_in_stage_success',
    SafeDiagnosticEvent.signInFailure => 'sign_in_failure',
    SafeDiagnosticEvent.sessionRestoreFailure => 'session_restore_failure',
    SafeDiagnosticEvent.sessionDeleteFailure => 'session_delete_failure',
  };
}

enum SafeDiagnosticReason {
  secureStorageMissingEntitlement,
  secureStorageUnavailable,
  secureStorageAccessDenied,
  secureStorageUnexpected,
  sessionPrepareFailed,
  sessionSaveFailed,
  activationFailed,
  alreadyInProgress,
  alreadySignedIn,
  embyApiFailure,
  unknown,
}

extension SafeDiagnosticReasonCode on SafeDiagnosticReason {
  String get code => switch (this) {
    SafeDiagnosticReason.secureStorageMissingEntitlement =>
      'secure_storage_missing_entitlement',
    SafeDiagnosticReason.secureStorageUnavailable =>
      'secure_storage_unavailable',
    SafeDiagnosticReason.secureStorageAccessDenied =>
      'secure_storage_access_denied',
    SafeDiagnosticReason.secureStorageUnexpected => 'secure_storage_unexpected',
    SafeDiagnosticReason.sessionPrepareFailed => 'session_prepare_failed',
    SafeDiagnosticReason.sessionSaveFailed => 'session_save_failed',
    SafeDiagnosticReason.activationFailed => 'activation_failed',
    SafeDiagnosticReason.alreadyInProgress => 'already_in_progress',
    SafeDiagnosticReason.alreadySignedIn => 'already_signed_in',
    SafeDiagnosticReason.embyApiFailure => 'emby_api_failure',
    SafeDiagnosticReason.unknown => 'unknown',
  };
}

enum SafeDiagnosticErrorType {
  secureStorageFailure,
  signInFailure,
  embyApiException,
  unknown,
}

extension SafeDiagnosticErrorTypeCode on SafeDiagnosticErrorType {
  String get code => switch (this) {
    SafeDiagnosticErrorType.secureStorageFailure => 'SecureStorageFailure',
    SafeDiagnosticErrorType.signInFailure => 'SignInFailure',
    SafeDiagnosticErrorType.embyApiException => 'EmbyApiException',
    SafeDiagnosticErrorType.unknown => 'Unknown',
  };
}

SafeDiagnosticReason safeReasonForStorage(SecureStorageFailureReason reason) =>
    switch (reason) {
      SecureStorageFailureReason.missingEntitlement =>
        SafeDiagnosticReason.secureStorageMissingEntitlement,
      SecureStorageFailureReason.unavailable =>
        SafeDiagnosticReason.secureStorageUnavailable,
      SecureStorageFailureReason.accessDenied =>
        SafeDiagnosticReason.secureStorageAccessDenied,
      SecureStorageFailureReason.unexpected =>
        SafeDiagnosticReason.secureStorageUnexpected,
    };

SafeDiagnosticReason safeReasonForSignIn(
  SignInFailureReason reason,
) => switch (reason) {
  SignInFailureReason.secureStorageMissingEntitlement =>
    SafeDiagnosticReason.secureStorageMissingEntitlement,
  SignInFailureReason.secureStorageUnavailable =>
    SafeDiagnosticReason.secureStorageUnavailable,
  SignInFailureReason.secureStorageAccessDenied =>
    SafeDiagnosticReason.secureStorageAccessDenied,
  SignInFailureReason.secureStorageUnexpected =>
    SafeDiagnosticReason.secureStorageUnexpected,
  SignInFailureReason.sessionPrepareFailed =>
    SafeDiagnosticReason.sessionPrepareFailed,
  SignInFailureReason.sessionSaveFailed =>
    SafeDiagnosticReason.sessionSaveFailed,
  SignInFailureReason.activationFailed => SafeDiagnosticReason.activationFailed,
  SignInFailureReason.alreadyInProgress =>
    SafeDiagnosticReason.alreadyInProgress,
  SignInFailureReason.alreadySignedIn => SafeDiagnosticReason.alreadySignedIn,
  SignInFailureReason.unknown => SafeDiagnosticReason.unknown,
};

enum SafeDiagnosticLevel { info, error }

extension SafeDiagnosticLevelCode on SafeDiagnosticLevel {
  String get code => switch (this) {
    SafeDiagnosticLevel.info => 'INFO',
    SafeDiagnosticLevel.error => 'ERROR',
  };
}

abstract interface class SafeDiagnosticEventSource {
  Future<List<SafeDiagnosticRecord>> readSafeEvents();

  Future<void> clearSafeEvents();
}

class SafeDiagnosticValidationException implements Exception {
  const SafeDiagnosticValidationException();
}

class SafeDiagnosticRecord {
  const SafeDiagnosticRecord({
    required this.atUtc,
    required this.level,
    required this.component,
    required this.event,
    required this.stage,
    required this.reason,
    required this.errorType,
  });

  final DateTime atUtc;
  final SafeDiagnosticLevel level;
  final SafeDiagnosticComponent component;
  final SafeDiagnosticEvent event;
  final SignInStage stage;
  final SafeDiagnosticReason reason;
  final SafeDiagnosticErrorType errorType;

  String get diagnosticCode => safeDiagnosticCodeFor(stage, reason);

  Map<String, Object> toJson() => <String, Object>{
    'atUtc': atUtc.toUtc().toIso8601String(),
    'level': level.code,
    'component': component.code,
    'event': event.code,
    'stage': stage.code,
    'reason': reason.code,
    'errorType': errorType.code,
    'diagnosticCode': diagnosticCode,
  };

  static SafeDiagnosticRecord fromJson(Object? value) {
    if (value is! Map) throw const SafeDiagnosticValidationException();
    final map = <String, Object?>{};
    for (final entry in value.entries) {
      if (entry.key is! String) {
        throw const SafeDiagnosticValidationException();
      }
      map[entry.key as String] = entry.value;
    }
    const keys = {
      'atUtc',
      'level',
      'component',
      'event',
      'stage',
      'reason',
      'errorType',
      'diagnosticCode',
    };
    if (map.length != keys.length || !map.keys.toSet().containsAll(keys)) {
      throw const SafeDiagnosticValidationException();
    }
    final atUtcValue = map['atUtc'];
    final levelValue = map['level'];
    final componentValue = map['component'];
    final eventValue = map['event'];
    final stageValue = map['stage'];
    final reasonValue = map['reason'];
    final errorTypeValue = map['errorType'];
    final diagnosticCodeValue = map['diagnosticCode'];
    if (atUtcValue is! String ||
        levelValue is! String ||
        componentValue is! String ||
        eventValue is! String ||
        stageValue is! String ||
        reasonValue is! String ||
        errorTypeValue is! String ||
        diagnosticCodeValue is! String ||
        _hasControlCharacter(map.values)) {
      throw const SafeDiagnosticValidationException();
    }
    final atUtc = DateTime.tryParse(atUtcValue);
    if (atUtc == null ||
        !atUtc.isUtc ||
        atUtc.toIso8601String() != atUtcValue) {
      throw const SafeDiagnosticValidationException();
    }
    final record = SafeDiagnosticRecord(
      atUtc: atUtc,
      level: _safeDiagnosticLevelFromCode(levelValue),
      component: _safeDiagnosticComponentFromCode(componentValue),
      event: _safeDiagnosticEventFromCode(eventValue),
      stage: _signInStageFromCode(stageValue),
      reason: _safeDiagnosticReasonFromCode(reasonValue),
      errorType: _safeDiagnosticErrorTypeFromCode(errorTypeValue),
    );
    if (record.diagnosticCode != diagnosticCodeValue) {
      throw const SafeDiagnosticValidationException();
    }
    return record;
  }
}

String safeDiagnosticCodeFor(
  SignInStage stage,
  SafeDiagnosticReason reason,
) => switch ((stage, reason)) {
  (
    SignInStage.deviceIdRead,
    SafeDiagnosticReason.secureStorageMissingEntitlement,
  ) =>
    'LOGIN-DID-READ-KC-MISSING',
  (SignInStage.deviceIdRead, SafeDiagnosticReason.secureStorageUnavailable) =>
    'LOGIN-DID-READ-KC-UNAVAILABLE',
  (SignInStage.deviceIdRead, SafeDiagnosticReason.secureStorageAccessDenied) =>
    'LOGIN-DID-READ-KC-DENIED',
  (SignInStage.deviceIdRead, SafeDiagnosticReason.secureStorageUnexpected) =>
    'LOGIN-DID-READ-KC-UNEXPECTED',
  (
    SignInStage.deviceIdWrite,
    SafeDiagnosticReason.secureStorageMissingEntitlement,
  ) =>
    'LOGIN-DID-WRITE-KC-MISSING',
  (SignInStage.deviceIdWrite, SafeDiagnosticReason.secureStorageUnavailable) =>
    'LOGIN-DID-WRITE-KC-UNAVAILABLE',
  (SignInStage.deviceIdWrite, SafeDiagnosticReason.secureStorageAccessDenied) =>
    'LOGIN-DID-WRITE-KC-DENIED',
  (SignInStage.deviceIdWrite, SafeDiagnosticReason.secureStorageUnexpected) =>
    'LOGIN-DID-WRITE-KC-UNEXPECTED',
  (
    SignInStage.sessionSave,
    SafeDiagnosticReason.secureStorageMissingEntitlement,
  ) =>
    'LOGIN-SESSION-SAVE-KC-MISSING',
  (SignInStage.sessionSave, SafeDiagnosticReason.secureStorageUnavailable) =>
    'LOGIN-SESSION-SAVE-KC-UNAVAILABLE',
  (SignInStage.sessionSave, SafeDiagnosticReason.secureStorageAccessDenied) =>
    'LOGIN-SESSION-SAVE-KC-DENIED',
  (SignInStage.sessionSave, SafeDiagnosticReason.secureStorageUnexpected) =>
    'LOGIN-SESSION-SAVE-KC-UNEXPECTED',
  (SignInStage.sessionPrepare, _) => 'LOGIN-SESSION-PREPARE',
  (SignInStage.activate, _) => 'LOGIN-ACTIVATE',
  (SignInStage.authenticate, SafeDiagnosticReason.embyApiFailure) =>
    'LOGIN-AUTH',
  _ => 'LOGIN-UNKNOWN',
};

bool _hasControlCharacter(Iterable<Object?> values) => values.any(
  (value) =>
      value is String &&
      value.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f),
);

SafeDiagnosticLevel _safeDiagnosticLevelFromCode(String value) =>
    switch (value) {
      'INFO' => SafeDiagnosticLevel.info,
      'ERROR' => SafeDiagnosticLevel.error,
      _ => throw const SafeDiagnosticValidationException(),
    };

SafeDiagnosticComponent _safeDiagnosticComponentFromCode(String value) =>
    switch (value) {
      'auth' => SafeDiagnosticComponent.auth,
      'storage' => SafeDiagnosticComponent.storage,
      _ => throw const SafeDiagnosticValidationException(),
    };

SafeDiagnosticEvent _safeDiagnosticEventFromCode(String value) =>
    switch (value) {
      'sign_in_stage_start' => SafeDiagnosticEvent.signInStageStart,
      'sign_in_stage_success' => SafeDiagnosticEvent.signInStageSuccess,
      'sign_in_failure' => SafeDiagnosticEvent.signInFailure,
      'session_restore_failure' => SafeDiagnosticEvent.sessionRestoreFailure,
      'session_delete_failure' => SafeDiagnosticEvent.sessionDeleteFailure,
      _ => throw const SafeDiagnosticValidationException(),
    };

SignInStage _signInStageFromCode(String value) => switch (value) {
  'PREFLIGHT' => SignInStage.preflight,
  'SESSION_READ' => SignInStage.sessionRead,
  'DEVICE_ID_READ' => SignInStage.deviceIdRead,
  'DEVICE_ID_WRITE' => SignInStage.deviceIdWrite,
  'AUTHENTICATE' => SignInStage.authenticate,
  'SESSION_PREPARE' => SignInStage.sessionPrepare,
  'SESSION_SAVE' => SignInStage.sessionSave,
  'ACTIVATE' => SignInStage.activate,
  'SESSION_DELETE' => SignInStage.sessionDelete,
  'ROLLBACK' => SignInStage.rollback,
  _ => throw const SafeDiagnosticValidationException(),
};

SafeDiagnosticReason _safeDiagnosticReasonFromCode(
  String value,
) => switch (value) {
  'secure_storage_missing_entitlement' =>
    SafeDiagnosticReason.secureStorageMissingEntitlement,
  'secure_storage_unavailable' => SafeDiagnosticReason.secureStorageUnavailable,
  'secure_storage_access_denied' =>
    SafeDiagnosticReason.secureStorageAccessDenied,
  'secure_storage_unexpected' => SafeDiagnosticReason.secureStorageUnexpected,
  'session_prepare_failed' => SafeDiagnosticReason.sessionPrepareFailed,
  'session_save_failed' => SafeDiagnosticReason.sessionSaveFailed,
  'activation_failed' => SafeDiagnosticReason.activationFailed,
  'already_in_progress' => SafeDiagnosticReason.alreadyInProgress,
  'already_signed_in' => SafeDiagnosticReason.alreadySignedIn,
  'emby_api_failure' => SafeDiagnosticReason.embyApiFailure,
  'unknown' => SafeDiagnosticReason.unknown,
  _ => throw const SafeDiagnosticValidationException(),
};

SafeDiagnosticErrorType _safeDiagnosticErrorTypeFromCode(String value) =>
    switch (value) {
      'SecureStorageFailure' => SafeDiagnosticErrorType.secureStorageFailure,
      'SignInFailure' => SafeDiagnosticErrorType.signInFailure,
      'EmbyApiException' => SafeDiagnosticErrorType.embyApiException,
      'Unknown' => SafeDiagnosticErrorType.unknown,
      _ => throw const SafeDiagnosticValidationException(),
    };
