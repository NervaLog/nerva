package dev.dailywombat.postgrest

import org.http4k.lens.BiDiBodyLens

interface PostgRestCompanion<A : Any> {
    val lens: BiDiBodyLens<A>
    val listLens: BiDiBodyLens<List<A>>
}