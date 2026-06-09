Pod::Spec.new do |s|
  s.name             = 'SyncSqlCipher'
  s.version          = '1.0.0'
  s.summary          = 'Synchronous, DispatchQueue-based SQLCipher wrapper for Swift.'
  s.homepage         = 'https://github.com/customerio/SyncSqlCipher'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { "CustomerIO Team" => "win@customer.io" }
  s.source           = { :git => 'https://github.com/customerio/SyncSqlCipher.git', :tag => s.version.to_s }

  s.swift_version     = '5.10'
  s.cocoapods_version = '>= 1.11.0'

  s.ios.deployment_target = '13.0'
  s.osx.deployment_target = '10.15'
  # visionOS is supported via Swift Package Manager; add s.visionos.deployment_target
  # = '1.0' here once CocoaPods visionOS support is required by your targets.

  # ---------------------------------------------------------------------------
  # Sources
  #
  # The C amalgamation, its headers, and all Swift sources compile into a
  # single SyncSqlCipher framework — no separate CSqlCipher target needed.
  # ---------------------------------------------------------------------------
  s.source_files = [
    'Sources/CSqlCipher/sqlite3.c',
    'Sources/CSqlCipher/include/*.h',
    'Sources/SyncSqlCipher/**/*.swift',
  ]

  # The C headers are an internal implementation detail of this framework.
  # Marking them private keeps them out of the generated umbrella header while
  # still making them available to the compiler via the header search path.
  s.private_header_files = 'Sources/CSqlCipher/include/*.h'

  # CocoaPods does not copy .modulemap files automatically, but the Swift
  # compiler needs it on disk to resolve `import CSqlCipher` (see
  # SWIFT_INCLUDE_PATHS below).
  s.preserve_paths = 'Sources/CSqlCipher/include/module.modulemap'

  # SQLCipher on Apple platforms uses CommonCrypto, which lives in Security.
  s.frameworks = 'Security'

  # ---------------------------------------------------------------------------
  # Build settings
  # ---------------------------------------------------------------------------
  s.pod_target_xcconfig = {
    # SQLCipher compile-time feature flags for sqlite3.c.
    #
    # SQLITE_HAS_CODEC=1 is load-bearing: omitting it produces a valid but
    # completely unencrypted SQLite database with no error at runtime.
    #
    # CocoaPods merges (not replaces) GCC_PREPROCESSOR_DEFINITIONS, so these
    # are additive alongside whatever the host project sets.
    'GCC_PREPROCESSOR_DEFINITIONS' =>
      'SQLITE_HAS_CODEC=1 ' \
      'SQLITE_TEMP_STORE=2 ' \
      'SQLITE_EXTRA_INIT=sqlcipher_extra_init ' \
      'SQLITE_EXTRA_SHUTDOWN=sqlcipher_extra_shutdown ' \
      'SQLCIPHER_CRYPTO_CC=1 ' \
      'SQLITE_THREADSAFE=1 ' \
      'HAVE_STDINT_H=1 ' \
      'NDEBUG=1 ' \
      'SQLITE_DQS=0',

    # Resolves `import CSqlCipher` in the Swift sources.
    #
    # The Swift compiler searches every directory listed here for module maps.
    # module.modulemap (preserved above) declares `module CSqlCipher { ... }`,
    # so the compiler finds it and the import works even though CSqlCipher is
    # not a separate CocoaPods target.
    'SWIFT_INCLUDE_PATHS' => '$(PODS_TARGET_SRCROOT)/Sources/CSqlCipher/include',

    # `internal import CSqlCipher` requires AccessLevelOnImport, which is an
    # experimental feature in Swift 5.10 (stable in Swift 6).
    'OTHER_SWIFT_FLAGS' => '$(inherited) -enable-experimental-feature AccessLevelOnImport',

    # Suppress warnings from the upstream SQLite C amalgamation (sqlite3.c).
    'OTHER_CFLAGS' => '$(inherited) -w',
  }

  # ---------------------------------------------------------------------------
  # Test spec
  #
  # Not installed by default. Consumers opt in with:
  #   pod 'SyncSqlCipher', :testspecs => ['Tests']
  # or by running:
  #   pod install --include-test-targets
  #
  # Run with:
  #   xcodebuild test \
  #     -workspace App.xcworkspace \
  #     -scheme SyncSqlCipher-Tests \
  #     -destination 'platform=iOS Simulator,name=iPhone 16'
  #
  # Requires Xcode 16+ — Swift Testing (@Suite / @Test / #expect) is
  # integrated with the XCTest runner from that version onward.
  # ---------------------------------------------------------------------------
  s.test_spec 'Tests' do |ts|
    ts.source_files = 'Tests/SyncSqlCipherTests/**/*.swift'
    ts.framework    = 'Foundation'
    # `import Testing` resolves automatically; no explicit declaration needed
    # because Swift Testing ships as a system framework in Xcode 16+.
  end
end
