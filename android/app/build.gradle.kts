plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "app.marginalia"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // Required by Readium.
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        applicationId = "app.marginalia"
        // Android 8.0, see the plan's platform decisions.
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // Release signing: the GitHub release workflow sets these; without them (local builds)
    // releases are signed with the debug key.
    val releaseKeystore = System.getenv("MARGINALIA_KEYSTORE")?.takeIf { file(it).exists() }
    signingConfigs {
        if (releaseKeystore != null) {
            create("release") {
                storeFile = file(releaseKeystore)
                storePassword = System.getenv("MARGINALIA_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("MARGINALIA_KEY_ALIAS")
                keyPassword = System.getenv("MARGINALIA_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName(if (releaseKeystore != null) "release" else "debug")
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
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

// 3.4.0 needs AGP 9.1 and compileSdk 37 (androidx.core 1.19); 3.3.0 matches Flutter's toolchain.
val readiumVersion = "3.3.0"

dependencies {
    implementation("org.readium.kotlin-toolkit:readium-shared:$readiumVersion")
    implementation("org.readium.kotlin-toolkit:readium-streamer:$readiumVersion")
    implementation("org.readium.kotlin-toolkit:readium-navigator:$readiumVersion")
    implementation("org.readium.kotlin-toolkit:readium-navigator-media-tts:$readiumVersion")
    implementation("androidx.media3:media3-session:1.10.0")
    implementation("androidx.fragment:fragment-ktx:1.8.9")
    implementation("androidx.palette:palette-ktx:1.0.0")
    // Kokoro voices, run on the phone (the model itself is downloaded in the app).
    implementation("com.github.k2-fsa:sherpa-onnx:v1.12.14")
    // Unpacking the voice model (.tar.bz2).
    implementation("org.apache.commons:commons-compress:1.27.1")
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
}
