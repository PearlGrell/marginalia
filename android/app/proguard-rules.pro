# MediaPipe (Gemma, for the reading companion): its native code reads these by name.
# Unused multimodal / image classes in tasks-genai are not bundled, so don't warn about them.
-keep class com.google.mediapipe.** { *; }
-keep class com.google.protobuf.** { *; }
-dontwarn com.google.mediapipe.**

# Readium keys a book's services (content, search, positions, ...) by their classes' simple
# names. Renamed, two can share a name ("a") and one replaces the other: losing the content
# service leaves Listen with "no text to read aloud".
-keepnames class org.readium.** { *; }


# The reader clears Readium's page view's "selecting" flag when it's left set (it drops taps
# while it is), finding it by name.
-keepclassmembers class org.readium.r2.navigator.R2BasicWebView { boolean isSelecting; }
