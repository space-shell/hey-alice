plugins {
    id("com.android.application")
}

android {
    namespace = "com.heyalice.overlay"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.heyalice.overlay"
        minSdk = 34
        targetSdk = 35
        versionCode = 1
        versionName = "0.1.0"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

// Runtime Resource Overlay targeting the framework (ADR-6): neutralises the
// power-menu long-press so ≥500 ms side-key holds belong to PTT alone.
// Must be preinstalled on a system partition (signature check) — see
// tools/overlay-install.sh for the root install + enable procedure.
