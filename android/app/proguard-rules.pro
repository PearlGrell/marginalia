# MediaPipe (Gemma, for the reading companion): its native code reads these by name.
# Unused multimodal / image classes in tasks-genai are not bundled, so don't warn about them.
-keep class com.google.mediapipe.** { *; }
-keep class com.google.protobuf.** { *; }
-dontwarn com.google.mediapipe.**

