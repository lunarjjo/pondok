plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.lunarjjo.pondok"
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.lunarjjo.pondok"
        // Android 7.0+ — the floor of the reference Termux/proot/Box64 stack.
        minSdk = 24
        // targetSdk 28 is DELIBERATE (architecture §2): sideloaded app that
        // must exec downloaded binaries (BDS, playit agent) from app-private
        // storage — the legacy SELinux domain for targetSdk<=28 permits it,
        // the same approach Termux uses. Consequences (sideload warning, no
        // Play Store) are accepted; see docs/RISK_REGISTER.md R-01.
        targetSdk = 28
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // CI signs with its own keystore later; local release uses debug keys.
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    lint {
        // targetSdk 28 is an architectural decision: the app must exec
        // downloaded binaries (BDS, playit agent) from app-private storage,
        // which the legacy SELinux domain (targetSdk <= 28) permits — the
        // same approach Termux uses (docs/ARCHITECTURE.md §2, RISK R-01).
        // This app is sideload-only and will never ship on Google Play, so
        // the Play-policy lint is disabled explicitly (not silenced globally).
        disable += "ExpiredTargetSdkVersion"
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
