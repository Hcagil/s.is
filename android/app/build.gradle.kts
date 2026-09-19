plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val releaseSigningValues = mapOf(
    "ANDROID_UPLOAD_KEYSTORE" to System.getenv("ANDROID_UPLOAD_KEYSTORE"),
    "ANDROID_UPLOAD_KEY_ALIAS" to System.getenv("ANDROID_UPLOAD_KEY_ALIAS"),
    "ANDROID_UPLOAD_STORE_PASSWORD" to System.getenv("ANDROID_UPLOAD_STORE_PASSWORD"),
    "ANDROID_UPLOAD_KEY_PASSWORD" to System.getenv("ANDROID_UPLOAD_KEY_PASSWORD"),
)
val missingReleaseSigningValues = releaseSigningValues.filterValues { it.isNullOrBlank() }.keys
val releaseBuildRequested = gradle.startParameter.taskNames.any {
    it.contains("release", ignoreCase = true)
}

if (releaseBuildRequested && missingReleaseSigningValues.isNotEmpty()) {
    throw GradleException(
        "Missing release signing environment: ${missingReleaseSigningValues.joinToString()}",
    )
}

android {
    namespace = "com.esd.sis"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.esd.sis"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (missingReleaseSigningValues.isEmpty()) {
            create("release") {
                storeFile = file(releaseSigningValues.getValue("ANDROID_UPLOAD_KEYSTORE")!!)
                keyAlias = releaseSigningValues.getValue("ANDROID_UPLOAD_KEY_ALIAS")
                storePassword = releaseSigningValues.getValue("ANDROID_UPLOAD_STORE_PASSWORD")
                keyPassword = releaseSigningValues.getValue("ANDROID_UPLOAD_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            if (missingReleaseSigningValues.isEmpty()) {
                signingConfig = signingConfigs.getByName("release")
            }
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
