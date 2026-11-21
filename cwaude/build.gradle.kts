// Qlaude (formerly Cwaude): Quest Claude without Termux. Runs its own Ubuntu (proot) and talks to tmux over a
// control-mode pipe. Run scripts/fetch-ubuntu-prebuilts.sh cwaude first; it fills
// src/main/jniLibs (proot) and src/main/assets (the Ubuntu rootfs).
plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "dev.cwaude"
    compileSdk = 35

    defaultConfig {
        applicationId = "dev.cwaude"
        minSdk = 29
        targetSdk = 34
        versionCode = (System.getenv("GITHUB_RUN_NUMBER") ?: "1").toInt()
        versionName = "0.1.${System.getenv("GITHUB_RUN_NUMBER") ?: "0"}"
        // Quest is arm64-only; skipping the other ABIs keeps the whisper.cpp build short.
        ndk { abiFilters += "arm64-v8a" }
    }

    // whisper.cpp for dictation: the same native code as the Quest Claude app, not a copy.
    externalNativeBuild {
        cmake {
            path = file("../app/src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    packaging {
        jniLibs {
            // Extract lib*.so to nativeLibraryDir: the only place this app may exec proot from.
            useLegacyPackaging = true
            // proot and its loader are executables; leave them exactly as built.
            keepDebugSymbols += listOf("**/libproot.so", "**/libproot-loader.so", "**/libtalloc.so", "**/libandroid-shmem.so")
        }
    }

    signingConfigs {
        // Same throwaway debug key as the other modules, so CI builds install over each other.
        getByName("debug") {
            storeFile = rootProject.file("debug.keystore")
            storeType = "pkcs12"
            storePassword = "android"
            keyAlias = "androiddebugkey"
            keyPassword = "android"
        }
    }

    buildTypes {
        debug { signingConfig = signingConfigs.getByName("debug") }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
}

dependencies {
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("org.apache.commons:commons-compress:1.27.1")
}
