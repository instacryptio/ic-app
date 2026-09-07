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

    // Silence "source/target value 8 is obsolete" warnings from
    // third-party Flutter plugins (super_native_extensions, etc.) that
    // still target Java 1.8. JDK 17 flags those as obsolete on every
    // compile; the JDK's own suppression for the obsolete-options
    // check is `-Xlint:-options` (literally what the warning text
    // suggests). Drop this once upstream plugins move to Java 11+.
    tasks.withType<JavaCompile>().configureEach {
        options.compilerArgs.add("-Xlint:-options")
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
