plugins {
    id("com.android.application") version "8.7.3" apply false
    id("org.jetbrains.kotlin.android") version "2.0.21" apply false
    id("org.jetbrains.kotlin.plugin.compose") version "2.0.21" apply false
}

allprojects {
    dependencyLocking { lockAllConfigurations() }
}

// Lock the plugin classpath (AGP, Kotlin) too, so scanners see build tooling.
buildscript {
    configurations.classpath { resolutionStrategy.activateDependencyLocking() }
}
