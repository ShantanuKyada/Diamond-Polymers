import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Signing details, kept out of the repository.
//
// `android/key.properties` names the keystore and its passwords. It is
// gitignored and written by CI from repository secrets; on a developer's
// machine it usually does not exist at all, and the release build falls back to
// the debug key below so `flutter run --release` still works.
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties().apply {
    if (keystorePropertiesFile.exists()) {
        FileInputStream(keystorePropertiesFile).use { load(it) }
    }
}
val hasReleaseKey = keystorePropertiesFile.exists()

android {
    namespace = "com.diamondpolymers.diamond_polymers"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // The identity Android installs and updates against. Changing it makes
        // a different app, not a new version of this one, so it is fixed.
        applicationId = "com.diamondpolymers.diamond_polymers"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseKey) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            // Android refuses to update an app whose signature has changed, so
            // every build handed to the factory has to be signed with the SAME
            // key. The debug key is not that: it is generated per machine, and
            // a CI runner is a new machine every time — which is why updating
            // over an installed build used to fail with "package conflicts with
            // an existing package" and only a full uninstall worked.
            //
            // Falls back to debug when there is no key.properties, so a
            // developer can still `flutter run --release` locally. A build made
            // that way installs fine on a clean phone and cannot update one
            // carrying a properly signed build — CI warns when it happens.
            signingConfig = if (hasReleaseKey) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

flutter {
    source = "../.."
}
