plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

fun androidVersionCode(versionName: String?, buildNumber: Int?): Int {
    val parts = versionName
        ?.split('.')
        ?.map { it.toIntOrNull() }
        ?: emptyList()
    require(parts.size == 3 && parts.all { it != null && it >= 0 }) {
        "pubspec version '$versionName' is not a MAJOR.MINOR.PATCH version, " +
            "so no stable Android version code can be derived from it"
    }
    val build = buildNumber ?: 1
    require(build in 0..9_999) {
        "build number $build does not fit the version-code layout (0..9999)"
    }
    return parts[0]!! * 100_000_000 +
        parts[1]!! * 1_000_000 +
        parts[2]!! * 10_000 +
        build
}

val releaseSigningValues = mapOf(
    "ARCADIAPLUS_KEYSTORE_PATH" to System.getenv("ARCADIAPLUS_KEYSTORE_PATH"),
    "ARCADIAPLUS_KEYSTORE_PASSWORD" to System.getenv("ARCADIAPLUS_KEYSTORE_PASSWORD"),
    "ARCADIAPLUS_KEY_ALIAS" to System.getenv("ARCADIAPLUS_KEY_ALIAS"),
    "ARCADIAPLUS_KEY_PASSWORD" to System.getenv("ARCADIAPLUS_KEY_PASSWORD"),
)
val hasAnyReleaseSigningValue = releaseSigningValues.values.any { !it.isNullOrBlank() }
val hasCompleteReleaseSigningConfig = releaseSigningValues.values.all { !it.isNullOrBlank() }
require(!hasAnyReleaseSigningValue || hasCompleteReleaseSigningConfig) {
    "Release signing requires all ARCADIAPLUS_KEYSTORE_* environment variables"
}

android {
    namespace = "com.blueokanna.arcadiaplus"
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
        applicationId = "com.blueokanna.arcadiaplus"
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = androidVersionCode(flutter.versionName, flutter.versionCode)
        versionName = flutter.versionName
        
        // Do not filter Flutter's supported armeabi-v7a, arm64-v8a, and x86_64
        // libraries. Android selects the matching ABI at install time.
    }

    signingConfigs {
        if (hasCompleteReleaseSigningConfig) {
            create("release") {
                storeFile = file(releaseSigningValues.getValue("ARCADIAPLUS_KEYSTORE_PATH")!!)
                storePassword = releaseSigningValues.getValue("ARCADIAPLUS_KEYSTORE_PASSWORD")
                keyAlias = releaseSigningValues.getValue("ARCADIAPLUS_KEY_ALIAS")
                keyPassword = releaseSigningValues.getValue("ARCADIAPLUS_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
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
