import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
    id("org.jetbrains.kotlin.plugin.serialization")
}

/**
 * Pulse's cloud keys (OpenRouter, Cartesia, TomTom), read from the same git-ignored file the iOS build uses:
 * `Config/Pulse.xcconfig.local`, written from `Backend/rag/.env` by `Tools/Pulse/write_app_keys.sh`.
 * A key in `android/local.properties` (e.g. `PULSE_TOMTOM_KEY=...`) wins. Without either, builds have no keys
 * and Pulse falls back to the backend / on-device guides, as on iOS. Keys inside an APK can be extracted,
 * so keep such builds on your own phones.
 */
val pulseKeys: Map<String, String> = run {
    val keys = mutableMapOf<String, String>()
    val xcconfig = rootProject.file("../Config/Pulse.xcconfig.local")
    if (xcconfig.exists()) {
        xcconfig.readLines()
            .map { it.substringBefore("//").trim() }
            .filter { it.contains("=") }
            .forEach { line -> keys[line.substringBefore("=").trim()] = line.substringAfter("=").trim() }
    }
    val local = rootProject.file("local.properties")
    if (local.exists()) {
        Properties().apply { local.inputStream().use(::load) }
            .forEach { (k, v) -> if (k.toString().startsWith("PULSE_")) keys[k.toString()] = v.toString() }
    }
    keys
}

fun pulseKey(name: String): String = "\"" + (pulseKeys[name] ?: "").replace("\"", "") + "\""

android {
    namespace = "org.cac.crashsafe"
    compileSdk = 35

    defaultConfig {
        applicationId = "org.cac.crashsafe"
        minSdk = 26
        targetSdk = 35
        versionCode = 1
        versionName = "0.1.0"

        buildConfigField("String", "PULSE_OPENROUTER_KEY", pulseKey("PULSE_OPENROUTER_KEY"))
        buildConfigField("String", "PULSE_CARTESIA_KEY", pulseKey("PULSE_CARTESIA_KEY"))
        buildConfigField("String", "PULSE_CARTESIA_BACKUP_KEY", pulseKey("PULSE_CARTESIA_BACKUP_KEY"))
        buildConfigField("String", "PULSE_TOMTOM_KEY", pulseKey("PULSE_TOMTOM_KEY"))
        // An HTTPS Pulse backend (`Backend/`), when deployed. Empty: none.
        buildConfigField("String", "RAG_ENDPOINT", pulseKey("PULSE_RAG_ENDPOINT"))
        // Debug phone builds: the Mac's Wi-Fi name/IP and the backend's LAN token (`serve --lan`).
        buildConfigField("String", "PULSE_LAN_HOST", pulseKey("PULSE_LAN_HOST"))
        buildConfigField("String", "PULSE_LAN_TOKEN", pulseKey("PULSE_LAN_TOKEN"))
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            // Signed with the debug key so `assembleRelease` produces an installable APK for testing.
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
    buildFeatures {
        compose = true
        buildConfig = true
    }
    packaging {
        resources.excludes += "/META-INF/{AL2.0,LGPL2.1}"
    }
    testOptions {
        unitTests.isReturnDefaultValues = true
        unitTests.isIncludeAndroidResources = true
        unitTests.all {
            // Screenshot tests (Robolectric + Roborazzi): render with real graphics and write the PNGs.
            it.systemProperty("robolectric.graphicsMode", "NATIVE")
            it.systemProperty("robolectric.pixelCopyRenderMode", "hardware")
            it.systemProperty("roborazzi.test.record", "true")
            it.maxHeapSize = "4g"
        }
    }
}

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2024.12.01")
    implementation(composeBom)
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-graphics")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.animation:animation")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    debugImplementation("androidx.compose.ui:ui-tooling")

    implementation("androidx.core:core-ktx:1.15.0")
    implementation("androidx.activity:activity-compose:1.9.3")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.7")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.7")
    implementation("androidx.lifecycle:lifecycle-process:2.8.7")

    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.7.3")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")

    // OpenStreetMap maps (no API key), Activity Recognition for "Watch every drive", Android Auto.
    implementation("org.osmdroid:osmdroid-android:6.1.20")
    implementation("com.google.android.gms:play-services-location:21.3.0")
    implementation("androidx.car.app:app:1.4.0")
    // play-services pulls in an old Fragment; 1.3+ is needed for registerForActivityResult.
    implementation("androidx.fragment:fragment-ktx:1.8.5")

    testImplementation("junit:junit:4.13.2")
    testImplementation("org.robolectric:robolectric:4.14.1")
    testImplementation("io.github.takahirom.roborazzi:roborazzi:1.32.2")
    testImplementation("io.github.takahirom.roborazzi:roborazzi-compose:1.32.2")
    testImplementation(composeBom)
    testImplementation("androidx.compose.ui:ui-test-junit4")
    debugImplementation("androidx.compose.ui:ui-test-manifest")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.9.0")
    testImplementation("com.squareup.okhttp3:mockwebserver:4.12.0")
}
