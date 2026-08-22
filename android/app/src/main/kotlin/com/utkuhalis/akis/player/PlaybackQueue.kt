package com.utkuhalis.akis.player

/**
 * Sırada çalacak videolar.
 *
 * Kuyruk NATIVE tarafta yaşar. Sebep: kullanıcı ekranı kapattığında Flutter
 * motoru askıya alınır ve Dart kodu çalışmaz; otomatik geçiş Dart'ta olsaydı
 * "parça bitti, sıradakine geç" hiç tetiklenmezdi.
 */
object PlaybackQueue {

    data class Item(
        val videoId: String,
        val title: String,
        val uploaderName: String?,
        val thumbnailUrl: String?
    )

    @Volatile
    private var items: List<Item> = emptyList()

    @Volatile
    var index: Int = -1
        private set

    @Volatile
    var autoplay: Boolean = true

    val size: Int get() = items.size

    fun snapshot(): List<Item> = items

    fun current(): Item? = items.getOrNull(index)

    fun set(newItems: List<Item>, startIndex: Int) {
        items = newItems
        index = startIndex
    }

    fun setAutoplayEnabled(enabled: Boolean) {
        autoplay = enabled
    }

    fun hasNext(): Boolean = index + 1 in items.indices

    fun hasPrevious(): Boolean = index - 1 in items.indices

    fun peekNext(): Item? = items.getOrNull(index + 1)

    /** Sıradakine ilerler ve onu döner; kuyruk bittiyse null. */
    fun advance(): Item? {
        val next = index + 1
        if (next !in items.indices) return null
        index = next
        return items[next]
    }

    fun back(): Item? {
        val previous = index - 1
        if (previous !in items.indices) return null
        index = previous
        return items[previous]
    }

    /** Kuyruktaki belirli bir konuma atlar. */
    fun jumpTo(target: Int): Item? {
        if (target !in items.indices) return null
        index = target
        return items[target]
    }

    fun clear() {
        items = emptyList()
        index = -1
    }
}
