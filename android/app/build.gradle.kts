plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    id("com.google.gms.google-services")
}

val releaseSigningValues = mapOf(
    "ANDROID_UPLOAD_KEYSTORE" to System.getenv("ANDROID_UPLOAD_KEYSTORE"),
    "ANDROID_UPLOAD_KEY_ALIAS" to System.getenv("ANDROID_UPLOAD_KEY_ALIAS"),
    "ANDROID_UPLOAD_STORE_PASSWORD" to System.getenv("ANDROID_UPLOAD_STORE_PASSWORD"),
    "ANDROID_UPLOAD_KEY_PASSWORD" to System.getenv("ANDROID_UPLOAD_KEY_PASSWORD"),
)
val missingReleaseSigningValues = releaseSigningValues.filterValues { it.isNullOrBlank() }.keys

// Google Maps key for the manifest: env (CI), else the git-ignored .private/maps.properties, else empty. An empty key never fails a build; the app then falls back to OpenStreetMap.
val mapsApiKey: String =
    System.getenv("MAPS_API_KEY_ANDROID")?.takeIf { it.isNotBlank() }
        ?: rootProject.file("../.private/maps.properties").takeIf { it.exists() }?.let { file ->
            java.util.Properties().apply { file.inputStream().use { load(it) } }
                .getProperty("MAPS_API_KEY_ANDROID")?.trim()
        }
        ?: ""
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
        // flutter_local_notifications uses java.time on older Android.
        isCoreLibraryDesugaringEnabled = true
    }

    // Robolectric tests draw notifications with the app's own icon and colour.
    testOptions.unitTests.isIncludeAndroidResources = true

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
        manifestPlaceholders["MAPS_API_KEY"] = mapsApiKey
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
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
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

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
    testImplementation("junit:junit:4.13.2")
    // android.jar's org.json is a stub in JVM unit tests; this is the real one.
    testImplementation("org.json:json:20240303")
    // Runs PushArrivalReceiver / InstantPush.show against Android's real framework classes on the JVM.
    testImplementation("org.robolectric:robolectric:4.14.1")
    testImplementation("androidx.test:core:1.6.1")
}

// With Android resources in unit tests, AGP packages the merged assets that the Flutter
// plugin's copyFlutterAssets<Variant> task writes; Gradle requires that order be declared.
tasks.configureEach {
    val variant = Regex("^package(\\w+)UnitTestForUnitTest$").find(name)?.groupValues?.get(1)
    if (variant != null) dependsOn("copyFlutterAssets$variant")
}
