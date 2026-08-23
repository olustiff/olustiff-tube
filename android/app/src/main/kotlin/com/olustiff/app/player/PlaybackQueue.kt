package com.olustiff.app.player

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

    /** Tekrar modu. */
    enum class RepeatMode { OFF, ONE, ALL }

    @Volatile
    var repeatMode: RepeatMode = RepeatMode.OFF
        private set

    @Volatile
    var shuffle: Boolean = false
        private set

    /**
     * Karıştırma açıkken kullanılan çalma sırası (öğe indeksleri).
     * Orijinal sıra bozulmaz; böylece karıştırma kapatılınca liste eski
     * hâline döner.
     */
    @Volatile
    private var order: List<Int> = emptyList()

    val size: Int get() = items.size

    fun snapshot(): List<Item> = items

    fun current(): Item? = items.getOrNull(index)

    fun set(newItems: List<Item>, startIndex: Int) {
        items = newItems
        index = startIndex
        rebuildOrder()
    }

    fun setRepeatMode(mode: RepeatMode) {
        repeatMode = mode
    }

    /** Karıştırmayı açar/kapatır; çalan parça yerinde kalır. */
    fun setShuffle(enabled: Boolean) {
        shuffle = enabled
        rebuildOrder()
    }

    private fun rebuildOrder() {
        val indices = items.indices.toList()
        order = if (!shuffle) {
            indices
        } else {
            // Çalan parça başta kalsın, kalanlar karışsın.
            val rest = indices.filter { it != index }.shuffled()
            if (index in indices) listOf(index) + rest else rest
        }
    }

    /** [index]'in çalma sırasındaki konumu. */
    private fun positionInOrder(): Int = order.indexOf(index)

    fun setAutoplayEnabled(enabled: Boolean) {
        autoplay = enabled
    }

    fun hasNext(): Boolean =
        repeatMode == RepeatMode.ALL || nextIndex() != null

    fun hasPrevious(): Boolean = previousIndex() != null

    fun peekNext(): Item? = nextIndex()?.let { items.getOrNull(it) }

    private fun nextIndex(): Int? {
        val position = positionInOrder()
        if (position == -1) return order.firstOrNull()
        val next = position + 1
        return when {
            next < order.size -> order[next]
            // Liste tekrarı: sona gelince başa dön.
            repeatMode == RepeatMode.ALL -> order.firstOrNull()
            else -> null
        }
    }

    private fun previousIndex(): Int? {
        val position = positionInOrder()
        if (position <= 0) return null
        return order[position - 1]
    }

    /**
     * Sıradakine ilerler ve onu döner; kuyruk bittiyse null.
     *
     * Tek parça tekrarında aynı öğe döner — çağıran taraf onu yeniden çalar.
     */
    fun advance(): Item? {
        if (repeatMode == RepeatMode.ONE) return current()
        val next = nextIndex() ?: return null
        index = next
        return items[next]
    }

    fun back(): Item? {
        val previous = previousIndex() ?: return null
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
        order = emptyList()
    }
}
