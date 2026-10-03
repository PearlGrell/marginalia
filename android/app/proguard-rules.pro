# sherpa-onnx (Kokoro voices): its native code reads these classes and fields by name, so
# release builds must not rename or remove them.
-keep class com.k2fsa.sherpa.onnx.** { *; }
