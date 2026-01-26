package dev.template.iam_stytch

import dev.dailywombat.postgrest.PostgRestError
import dev.dailywombat.stytch.StytchError
import dev.dailywombat.stytch.StytchRedirectToken.Companion.TokenType

sealed interface IamStytchError {
    data class Stytch(val error: StytchError) : IamStytchError
    data class PostgRest(val error: PostgRestError) : IamStytchError
    data class UnsupportedTokenType(val type: TokenType) : IamStytchError
}
