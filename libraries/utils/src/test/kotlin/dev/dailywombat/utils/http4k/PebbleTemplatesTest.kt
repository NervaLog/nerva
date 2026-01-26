package dev.dailywombat.utils.http4k

import dev.dailywombat.utils.ViewLenses
import io.kotest.matchers.shouldBe
import org.http4k.template.ViewModel
import org.junit.jupiter.api.Test
import java.io.File

internal data class Dingbumps(
    val thingamajig: String,
    val thingamabob: String
) : ViewModel

class PebbleTemplatesTest {

    @Test
    fun `Test Pebble Dev and Test Setup`() {
        val renderer = ViewLenses.hotReload(isTest = true)
        val whatchmacallit = Dingbumps(
            thingamajig = "this sh*t",
            thingamabob = "that sh*t"
        )

        val templatePath = "src/test/resources/dev/nerva/utils/http4k/Dingbumps.peb"
        File(templatePath).apply {
            parentFile.mkdirs()
            writeText("""{{ model.thingamajig }}""")
        }
        renderer(whatchmacallit) shouldBe whatchmacallit.thingamajig

        //  Overwrite the template to test hot reload.
        File(templatePath).apply {
            writeText("""{{ model.thingamabob }}""")
        }
        renderer(whatchmacallit) shouldBe whatchmacallit.thingamabob

        //  Overwrite the template to test hot reload.
        File(templatePath).apply {
            writeText("""{{ model.thingamajig }}""")
        }
        renderer(whatchmacallit) shouldBe whatchmacallit.thingamajig
    }
}
