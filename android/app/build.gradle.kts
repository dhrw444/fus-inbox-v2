import java.util.Properties
import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(keystorePropertiesFile.inputStream())
}

android {
    namespace = "com.yg.fusv2"
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.yg.fusv2"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // The app ships English-only; strip translated strings bundled by
        // libraries (material, webview, androidx) to shrink resources.arsc.
        resourceConfigurations.add("en")
    }

    signingConfigs {
        create("release") {
            keyAlias = keystoreProperties.getProperty("keyAlias")
            keyPassword = keystoreProperties.getProperty("keyPassword")
            storeFile = keystoreProperties.getProperty("storeFile")?.let { file(it) }
            storePassword = keystoreProperties.getProperty("storePassword")
        }
    }

    buildTypes {
        release {
            // **没有 key.properties 就不挂 release 签名。**
            //
            // 无条件是错的：gradle 的 `validateSigningRelease` 会直接报
            // 「Keystore file not set for signing config release」，
            // 整个构建失败 —— 连 unsigned 包都出不来。那样「没有密钥时
            // 明确出一个 unsigned 包」这句承诺就是假的。
            //
            // 挂不上的时候产物是 `app-arm64-v8a-release-unsigned.apk`，
            // 文件名自己会说明它装不上。
            if (keystorePropertiesFile.exists()) {
                signingConfig = signingConfigs.getByName("release")
            }
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
    compileSdkMinor = 1
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
    implementation("com.google.android.material:material:1.14.0")
    // addDocumentStartJavaScript 需要它。webview_flutter_android 内部
    // 已经传递依赖了 androidx.webkit，但显式声明才不会在某次升级后
    // 悄悄消失导致编译失败。
    implementation("androidx.webkit:webkit:1.14.0")
}
