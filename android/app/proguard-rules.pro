# kotlinx.serialization
-keepattributes *Annotation*, InnerClasses
-dontnote kotlinx.serialization.AnnotationsKt
-keepclassmembers class kotlinx.serialization.json.** { *** Companion; }
-keepclasseswithmembers class kotlinx.serialization.json.** { kotlinx.serialization.KSerializer serializer(...); }
-keep,includedescriptorclasses class org.cac.crashsafe.**$$serializer { *; }
-keepclassmembers class org.cac.crashsafe.** { *** Companion; }
-keepclasseswithmembers class org.cac.crashsafe.** { kotlinx.serialization.KSerializer serializer(...); }

# osmdroid, OkHttp
-dontwarn org.osmdroid.**
-dontwarn okhttp3.**
-dontwarn okio.**
-dontwarn org.conscrypt.**
-dontwarn org.bouncycastle.**
-dontwarn org.openjsse.**

# Android Auto screens are created by the host by class name.
-keep class org.cac.crashsafe.services.carapp.** { *; }
