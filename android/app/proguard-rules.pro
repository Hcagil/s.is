# flutter_local_notifications reads and writes its scheduled list with Gson
# and a TypeToken. R8 strips the generic signature, and cancel()/cancelAll()
# then throw "Missing type parameter" -- in release builds only.
-keepattributes Signature
-keepattributes *Annotation*
-keep class com.google.gson.reflect.TypeToken { *; }
-keep class * extends com.google.gson.reflect.TypeToken
-keep class com.dexterous.flutterlocalnotifications.models.** { *; }

# Release optimisation stays off, as it was before these rules existed.
-dontoptimize
