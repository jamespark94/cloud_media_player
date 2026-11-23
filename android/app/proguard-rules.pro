# Flutter Wrapper & Engine
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.**  { *; }
-keep class io.flutter.util.**  { *; }
-keep class io.flutter.view.**  { *; }
-keep class io.flutter.**  { *; }
-keep class io.flutter.plugins.** { *; }
-dontwarn io.flutter.**

# MediaKit & libmpv Native JNI bindings
-keep class com.alexmercerind.mediakit.** { *; }
-keep class com.alexmercerind.mediakit_video.** { *; }
-keep class com.alexmercerind.mediakit_libs_android_video.** { *; }
-dontwarn com.alexmercerind.**

# FilePicker plugin
-keep class com.mr.flutter.plugin.filepicker.** { *; }
-dontwarn com.mr.flutter.plugin.filepicker.**

# Permission Handler
-keep class com.baseflow.permissionhandler.** { *; }
-dontwarn com.baseflow.permissionhandler.**

# General JNI keep
-keepclasseswithmembernames class * {
    native <methods>;
}

# Firebase Components & ML Kit ComponentRegistrars
# (AGP/R8 full mode strips no-arg <init>() if only class is kept without members)
-keep class * implements com.google.firebase.components.ComponentRegistrar {
    <init>();
    *;
}
-keep class com.google.firebase.components.** { *; }

# Google ML Kit Translation & Common
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.internal.mlkit_common.** { *; }
-keep class com.google.android.gms.internal.mlkit_translate.** { *; }
-keep class com.google_mlkit_translation.** { *; }
-keep class com.google_mlkit_commons.** { *; }
-dontwarn com.google.mlkit.**
