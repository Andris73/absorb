# Broad Flutter keep, applied only to the github + playstore flavors (wired up
# in build.gradle.kts productFlavors). The fdroid flavor intentionally omits
# this so R8 can strip Flutter's unused deferred-components manager, which
# otherwise pulls proprietary Google Play Core class references into the APK and
# trips F-Droid's non-free scanner.
-keep class io.flutter.** { *; }
