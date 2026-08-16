import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    // Google Services — reads google-services.json for the Firebase SDKs.
    id("com.google.gms.google-services")
}

// ── Release signing ────────────────────────────────────────────────────────
// Until 2026-08-16 the release buildType was still on the Flutter template's
// `signingConfig = signingConfigs.getByName("debug")`, so every "release" APK
// ever produced — including the ones handed to beta testers through Firebase —
// was signed with the local debug key. That cannot be uploaded to Play, and it
// left Android App Links unverifiable because no release certificate existed
// whose SHA-256 could go into assetlinks.json.
//
// Nile uses PLAY APP SIGNING, so this is the UPLOAD key, not the final app
// signing key — Google re-signs the app with a key it holds. The consequence
// worth remembering: there are TWO fingerprints and App Links need both.
//   • upload key                → signs local + Firebase App Distribution builds
//   • Play app signing key      → signs whatever users install from Play
//     (Play Console → Test and release → Setup → App integrity)
// Both belong in the assetlinks.json the `share` Edge Function serves.
//
// key.properties and the keystore itself are gitignored. Never commit either.
// See android/key.properties.example for the expected keys.
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties().apply {
    if (keystorePropertiesFile.exists()) {
        keystorePropertiesFile.inputStream().use { load(it) }
    }
}

// Fail loudly rather than silently producing a debug-signed "release" — that is
// exactly the bug this block replaces. If you want an unsigned build to poke
// at, build the debug variant instead.
if (!keystorePropertiesFile.exists() &&
    gradle.startParameter.taskNames.any { it.contains("Release", ignoreCase = true) }
) {
    throw GradleException(
        """
        Release build requested but android/key.properties is missing, so there
        is no upload key to sign with.

        Create it from android/key.properties.example and point storeFile at the
        upload keystore (kept OUTSIDE the repo). Refusing to fall back to the
        debug key: a debug-signed release cannot be uploaded to Play and breaks
        App Links verification.
        """.trimIndent()
    )
}

android {
    namespace = "com.nilestreaming.app"
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.nilestreaming.app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            if (keystorePropertiesFile.exists()) {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
