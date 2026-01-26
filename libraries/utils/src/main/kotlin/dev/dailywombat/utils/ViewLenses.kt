package dev.dailywombat.utils

import org.http4k.template.PebbleTemplates
import org.http4k.template.TemplateRenderer
import org.http4k.template.Templates
import java.nio.file.Path
import kotlin.io.path.pathString

object ViewLenses {

    fun caching(templates: Templates = PebbleTemplates()) =
        templates.CachingClasspath("")

    /**
     * Hot reload templates from resources directory.
     * Templates are located at: src/{main|test}/resources/{package-path}/{ClassName}.peb
     */
    fun hotReload(
        isTest: Boolean,
        templates: Templates = PebbleTemplates()
    ): TemplateRenderer =
        templates.HotReload(
            baseTemplateDir = Path.of(
                "src",
                if (isTest) "test" else "main",
                "resources"
            ).pathString
        )
}