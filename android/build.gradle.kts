allprojects {
    repositories {
        google()
        mavenCentral()
        // sherpa-onnx (Kokoro voices) is published there.
        maven {
            url = uri("https://jitpack.io")
            content { includeGroupByRegex("com\\.github\\.k2-fsa.*") }
        }
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
