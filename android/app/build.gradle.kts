plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

val releaseSigningValues = mapOf(
    "ARCADIA_KEYSTORE_PATH" to System.getenv("ARCADIA_KEYSTORE_PATH"),
    "ARCADIA_KEYSTORE_PASSWORD" to System.getenv("ARCADIA_KEYSTORE_PASSWORD"),
    "ARCADIA_KEY_ALIAS" to System.getenv("ARCADIA_KEY_ALIAS"),
    "ARCADIA_KEY_PASSWORD" to System.getenv("ARCADIA_KEY_PASSWORD"),
)
val hasAnyReleaseSigningValue = releaseSigningValues.values.any { !it.isNullOrBlank() }
val hasCompleteReleaseSigningConfig = releaseSigningValues.values.all { !it.isNullOrBlank() }
require(!hasAnyReleaseSigningValue || hasCompleteReleaseSigningConfig) {
    "Release signing requires all ARCADIA_KEYSTORE_* environment variables"
}

android {
    namespace = "com.blueokanna.arcadia"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "28.2.13676358"

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.blueokanna.arcadia"
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        
        // Do not filter Flutter's supported armeabi-v7a, arm64-v8a, and x86_64
        // libraries. Android selects the matching ABI at install time.
    }

    signingConfigs {
        if (hasCompleteReleaseSigningConfig) {
            create("release") {
                storeFile = file(releaseSigningValues.getValue("ARCADIA_KEYSTORE_PATH")!!)
                storePassword = releaseSigningValues.getValue("ARCADIA_KEYSTORE_PASSWORD")
                keyAlias = releaseSigningValues.getValue("ARCADIA_KEY_ALIAS")
                keyPassword = releaseSigningValues.getValue("ARCADIA_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            // A missing keystore must not fail the build: fall back to the
            // debug key so a release build still yields an installable APK.
            signingConfig =
                if (hasCompleteReleaseSigningConfig) {
                    signingConfigs.getByName("release")
                } else {
                    signingConfigs.getByName("debug")
                }
            isMinifyEnabled = true
            isShrinkResources = true
        }
    }
    
    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.7.3")
}
