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
