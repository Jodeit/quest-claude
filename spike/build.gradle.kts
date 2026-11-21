// Exec spike: can an app at targetSdk 34 run proot + an Ubuntu rootfs on its own, without Termux?
// Run scripts/fetch-ubuntu-prebuilts.sh first; it fills src/main/jniLibs and src/main/assets.
plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "dev.questclaude.spike"
    compileSdk = 35

    defaultConfig {
        applicationId = "dev.questclaude.spike"
        minSdk = 29
        // The point of the spike: a modern targetSdk, where exec from app data is blocked (W^X).
        targetSdk = 34
        versionCode = (System.getenv("GITHUB_RUN_NUMBER") ?: "1").toInt()
        versionName = "spike.${System.getenv("GITHUB_RUN_NUMBER") ?: "0"}"
        ndk { abiFilters += "arm64-v8a" }
    }

    packaging {
        jniLibs {
            // Extract the lib*.so files to nativeLibraryDir: the only exec-allowed app location.
            useLegacyPackaging = true
            // Some are executables, not libraries; leave them exactly as Termux built them.
            keepDebugSymbols += "**/*.so"
        }
    }

    signingConfigs {
        getByName("debug") {
            storeFile = rootProject.file("debug.keystore")
            storeType = "pkcs12"
            storePassword = "android"
            keyAlias = "androiddebugkey"
            keyPassword = "android"
        }
    }
    buildTypes { debug { signingConfig = signingConfigs.getByName("debug") } }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
}

dependencies {
    implementation("org.apache.commons:commons-compress:1.27.1")
}
