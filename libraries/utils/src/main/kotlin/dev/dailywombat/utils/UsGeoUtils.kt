package dev.dailywombat.utils

object UsGeoUtils {

    /**
     * Regex for:
     * ^        -> start of the string
     * (\d{5})  -> capture group 1: exactly five digits
     * (-\d{4})? -> optional group: a hyphen followed by exactly four digits
     * $        -> end of the string
     *
     * @param zipCode The string to validate.
     * @return true if the string is a valid US zip code format, false otherwise.
     */
    fun String.isValidUsZipCode(): Boolean =
        matches(Regex("^\\d{5}(-\\d{4})?$"))
}