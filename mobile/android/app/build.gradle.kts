import java.net.URI

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "dev.phonebridge.phonebridge"
    compileSdk = 36
    ndkVersion = flutter.ndkVersion
    System.getenv("PHONEBRIDGE_NDK_PATH")?.takeIf { it.isNotBlank() }?.let {
        ndkPath = it
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "dev.phonebridge.phonebridge"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 30
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // Test APK only; no fixture entry point is included in the production application.
        testInstrumentationRunner = providers.gradleProperty("phonebridgeTestRunner")
            .getOrElse("dev.phonebridge.phonebridge.SavedComputerFixtureInstrumentation")
        resValue("string", "update_manifest_url", "https://xn--8ovp9s.xn--m8txu.com/phonebridge/update.json")
    }

    signingConfigs {
        // The preview signer keeps existing installs upgradable. Supply it explicitly from
        // outside the repository; release builds never fall back to a key found on disk.
        System.getenv("PHONEBRIDGE_SIGNING_STORE")?.takeIf { it.isNotBlank() }?.let { store ->
            create("preview") {
                storeFile = file(store)
                storePassword = System.getenv("PHONEBRIDGE_SIGNING_STORE_PASSWORD")
                keyAlias = System.getenv("PHONEBRIDGE_SIGNING_KEY_ALIAS")
                keyPassword = System.getenv("PHONEBRIDGE_SIGNING_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        getByName("release") {
            signingConfigs.findByName("preview")?.let { signingConfig = it }
        }
        getByName("debug") {
            // Compile-time bootstrap fixture only. Release always uses the official resource.
            System.getenv("PHONEBRIDGE_TEST_UPDATE_MANIFEST")?.takeIf { it.isNotBlank() }?.let {
                val uri = URI(it)
                val host = uri.host ?: error("Test update URL requires a private IPv4 address")
                val parts = host.split('.').map { part -> part.toIntOrNull() ?: -1 }
                require(uri.scheme == "http" && uri.userInfo == null && uri.fragment == null &&
                    parts.size == 4 && parts.all { part -> part in 0..255 } &&
                    (parts[0] == 10 || (parts[0] == 172 && parts[1] in 16..31) ||
                        (parts[0] == 192 && parts[1] == 168))) {
                    "Test update manifest must use a private IPv4 HTTP origin"
                }
                resValue("string", "update_manifest_url", it)
            }
        }
    }
    // Release signing must be configured explicitly; never substitute debug keys.
}

flutter {
    source = "../.."
}

dependencies {
    implementation("androidx.core:core:1.15.0")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20240303")
}
