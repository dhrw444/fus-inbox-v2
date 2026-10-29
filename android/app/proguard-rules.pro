# Flutter specific rules
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }

# Keep Flutter engine
-keep class io.flutter.embedding.** { *; }

# WebView - keep JavaScript interface methods
-keepclassmembers class * {
    @android.webkit.JavascriptInterface <methods>;
}

# Keep webview_flutter classes
-keep class io.flutter.plugins.webviewflutter.** { *; }

# Keep shared_preferences classes
-keep class io.flutter.plugins.sharedpreferences.** { *; }

# Keep dynamic_color classes
-keep class io.material.materialcolorplugin.** { *; }

# Suppress warnings for optional plugin classes we do not ship.
-dontwarn io.flutter.embedding.**

# Keep Kotlin metadata
-keep class kotlin.Metadata { *; }
-keepclassmembers class kotlin.Metadata {
    public <methods>;
}

# Keep annotation classes
-keepattributes *Annotation*
-keepattributes Signature
-keepattributes InnerClasses
-keepattributes EnclosingMethod

# Keep native methods
-keepclasseswithmembernames class * {
    native <methods>;
}
