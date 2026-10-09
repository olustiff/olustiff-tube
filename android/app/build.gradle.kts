plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.olustiff.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.olustiff.app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    testOptions {
        // android.util.Log gibi çağrılar JVM testinde patlamasın.
        unitTests.isReturnDefaultValues = true
    }

    buildTypes {
        release {
            // Kişisel/sideload kullanım: debug anahtarıyla imzalanıyor.
            signingConfig = signingConfigs.getByName("debug")
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

flutter {
    source = "../.."
}

dependencies {
    // YouTube reklamsız stream çözümleme (NewPipe'ın kullandığı kütüphanenin aynısı)
    implementation("com.github.TeamNewPipe:NewPipeExtractor:v0.26.5")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.11.0")
    // Çözümleyicinin canlı testi (bkz. LiveExtractorTest).
    testImplementation("junit:junit:4.13.2")

    // Oynatma: arka planda müzik/medya oturumu + video render (Faz 2)
    implementation("androidx.media3:media3-exoplayer:1.11.1")
    // Canlı yayınlar (7/24 radyo vb.) yalnızca HLS manifesti üzerinden gelir.
    implementation("androidx.media3:media3-exoplayer-hls:1.11.1")
    // "Otomatik" kalite: tüm çözünürlükler tek bir DASH manifestinde toplanır
    // ve oynatıcı bant genişliğine göre aralarında geçiş yapar.
    implementation("androidx.media3:media3-exoplayer-dash:1.11.1")
    implementation("androidx.media3:media3-session:1.11.1")
    implementation("androidx.media3:media3-ui:1.11.1")
    implementation("androidx.media3:media3-datasource-okhttp:1.11.1")
    // MP3 kodlama: Android'in kendi kodlayıcılarında MP3 YOKTUR (yalnızca
    // çözücü var), bu yüzden LAME'in Android derlemesini gömüyoruz.
    // isTransitive=false: kütüphane eski com.android.support paketlerini
    // sürüklüyor ve AndroidX ile çakışıyor. Bize yalnızca LAME sınıfları ve
    // native kütüphane gerekiyor.
    implementation("com.github.naman14:TAndroidLame:1.1") { isTransitive = false }
}
