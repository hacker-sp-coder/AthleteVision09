allprojects {
    repositories {
        google()
        mavenCentral()
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

// Workaround: camera-core declares androidx.concurrent:concurrent-futures with
// "runtime" scope in its POM, which Gradle 9.x's stricter classpath isolation no
// longer promotes to the compile classpath, breaking camera_android_camerax's own
// build (javac fails resolving CallbackToFutureAdapter referenced by type
// annotations in SurfaceRequest.class). Add it explicitly on that subproject.
subprojects {
    plugins.withId("com.android.library") {
        if (name == "camera_android_camerax") {
            dependencies {
                add("implementation", "androidx.concurrent:concurrent-futures:1.2.0")
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
