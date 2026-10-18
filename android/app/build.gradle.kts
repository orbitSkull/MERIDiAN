plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    // Turn google-services.json into the values firebase_core reads at runtime.
    //
    // This plugin FAILS THE BUILD if the file is missing, which is deliberate and
    // worth knowing about: until the Firebase project exists, `flutter build apk`
    // stops here with a message naming the file. `flutter analyze` and
    // `flutter test` are unaffected, so the rest of the app stays verifiable.
    id("com.google.gms.google-services")
}

android {
    // Must match the Kotlin package of MainActivity, and must match the package
    // name registered in Firebase for push. Firebase treats it as permanent: a
    // different applicationId is a different app as far as FCM is concerned, so
    // changing one without the other means notifications that never arrive and no
    // error explaining why.
    namespace = "com.meridian.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // The published identity of the app. Firebase's "Add app -> Android"
        // step asks for exactly this string, and it cannot be edited afterwards.
        applicationId = "com.meridian.app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
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
