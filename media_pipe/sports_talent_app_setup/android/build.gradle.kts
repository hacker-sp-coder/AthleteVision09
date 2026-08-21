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

// Workaround: tflite_flutter's Android module doesn't pin a JVM toolchain,
// so its Kotlin compile task inherits whatever JDK invoked Gradle while its
// Java compile task defaults to an older target, which Gradle 9's stricter
// validation rejects outright ("Inconsistent JVM Target Compatibility").
// Force both to the same target (17) already used by the app module.
subprojects {
    if (name == "tflite_flutter") {
        // afterEvaluate so this runs after tflite_flutter's own build.gradle
        // has already set (and would otherwise win with) its own
        // compileOptions.
        afterEvaluate {
            extensions.configure<com.android.build.gradle.LibraryExtension> {
                compileOptions {
                    sourceCompatibility = JavaVersion.VERSION_17
                    targetCompatibility = JavaVersion.VERSION_17
                }
            }
        }
        tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
            compilerOptions.jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
